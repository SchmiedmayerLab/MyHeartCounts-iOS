//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length

@preconcurrency import FirebaseStorage
import Foundation
import Grove
import GroveAccount
import GroveFoundation
import OSLog
import SwiftData
import enum SwiftUI.ScenePhase
import Synchronization


/// Uploads files into the current user's directory in the Firebase Storage.
///
/// Pending uploads are tracked in a small database, with one ``ScheduledUpload`` entry per file;
/// the files themselves are kept in a flat staging directory, named after their entry's ``ScheduledUpload/id``.
/// Uploads are persistent: if an upload cannot be completed during the current launch of the app
/// (e.g.: missing network connection, no logged-in user, app getting terminated), it will be retried on subsequent launches.
///
/// - Note: this is intentionally a plain ``Grove/Module`` rather than a `ServiceModule`: a `ServiceModule`'s `run()` is
///     only ever reached via `.task(spezi.run)` in Grove's view modifier, which the app applies inside its `WindowGroup`.
///     A launch that connects no scene — a `BGTask` wake, or HealthKit background delivery — would therefore never start it,
///     i.e. exactly the situations this module exists to serve. `configure()` runs on every launch, so the drain starts there.
///
/// The queue makes progress whenever the process is alive: every launch (foreground or background) re-queues the backlog,
/// every return to the foreground does so again, and failed attempts are retried within the launch with a growing delay.
/// On top of that, the module registers a background task of its own (``MHCBackgroundTasks/TaskIdentifier/fileUpload``),
/// so that a backlog also gets drained on devices that are rarely opened, instead of only whenever some other module's
/// background task happens to wake the app.
@Observable
@MainActor
final class ManagedFileUpload: Grove::Module, EnvironmentAccessible, Sendable {
    /// Uploads a staged file on the module's behalf.
    ///
    /// `filename` is the name the file must be given remotely — always exactly the `lastPathComponent` the caller
    /// handed to ``stage(_:category:accountDataGeneration:metadata:)``, never the (uniquified) on-disk staging name.
    typealias UploadOperation = @Sendable (
        _ fileUrl: URL,
        _ category: Category,
        _ accountId: String,
        _ filename: String,
        _ metadata: [String: String]
    ) async throws -> Void

    /// Where the module keeps its state, how it talks to the outside world, and how much work it does at once.
    ///
    /// The defaults are what the app uses; the injection points exist so that the upload path — the one part of the
    /// app that handles participant data on its way off the device — can be tested without a Firebase environment.
    struct Configuration: Sendable {
        /// The directory holding the staged files (and any not-yet-migrated legacy per-category directories).
        var directory: URL = .documentsDirectory.appending(
            component: "ManagedFileUploading",
            directoryHint: .isDirectory
        )
        /// The directory holding the pending-uploads database.
        ///
        /// Deliberately outside ``directory``, so that ``ManagedFileUpload/clearPendingUploads()`` cannot destroy
        /// the index it is iterating.
        var databaseDirectory: URL = .applicationSupportDirectory.appending(
            component: "ManagedFileUpload",
            directoryHint: .isDirectory
        )
        /// Whether to keep the database in memory instead of on disk.
        var isStoredInMemoryOnly = false
        /// How many files may be uploaded concurrently.
        ///
        /// Each in-flight upload retains its request body, and the module always spends someone else's background
        /// execution budget, so this is kept deliberately small.
        var maximumConcurrentUploads = 2
        /// Resolves the currently signed-in account's id; `nil` to read it from the `Account` module.
        var accountIdProvider: (@Sendable () async -> String?)?
        /// Performs the actual upload; `nil` to upload into the Firebase Storage.
        var uploadOperation: UploadOperation?
        /// Whether data belonging to a previous account still needs to be cleared.
        var isCleanupPending: @Sendable () -> Bool = {
            LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired]
        }
        /// How long to wait before retrying an upload that failed during the current launch, based on how often it has failed so far;
        /// `nil` to stop retrying until the next ``ManagedFileUpload/resumePendingUploads()``.
        ///
        /// Default: retries after 30 s, 1 min, 2 min, 4 min and 8 min; anything that still fails after that is left to the next resume.
        var retryDelay: @Sendable (_ failedAttempts: Int) -> Duration? = { failedAttempts in
            guard (1...5).contains(failedAttempts) else {
                return nil
            }
            return .seconds(30 << (failedAttempts - 1))
        }
    }

    private enum UploadError: Error, Sendable {
        case databaseUnavailable
        case noAccount
        case cancelled
    }

    /// The outcome of a single upload attempt, as seen by the queue's bookkeeping.
    private enum UploadOutcome: Sendable {
        /// The file was uploaded and its entry removed.
        case completed
        /// The attempt failed; the entry survives and will be retried on a later resume or launch.
        case failed
        /// The entry is gone (already cleared, its file was missing, or it belongs to a different account).
        case discarded
    }

    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    @ObservationIgnored @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    @ObservationIgnored @Dependency(Lifecycle.self) private var lifecycle
    // swiftlint:enable attributes

    nonisolated let configuration: Configuration
    nonisolated(unsafe) private let fileManager = FileManager()

    private let newUploads = AsyncStream.makeStream(of: PersistentIdentifier.self)
    /// Whether the queue currently accepts new work.
    ///
    /// Set to `false` by ``cancelAndWaitForQuiescence()`` and back to `true` as the unconditional first step of
    /// ``resumePendingUploads()``, so that a failed or early-returning resume can never leave the queue closed.
    private var acceptsUploads = true
    /// Uploads that have been handed to the queue and haven't finished yet, and the category each was counted into.
    ///
    /// Entries are removed again when the upload finishes, in any way — unlike a plain "already seen" set, a
    /// failed upload therefore stays eligible for a later retry instead of being blacklisted for the launch.
    private var enqueuedUploads: [PersistentIdentifier: Category] = [:]
    /// The currently in-flight uploads, so that they can be cancelled and awaited.
    private var activeUploads: [PersistentIdentifier: Swift::Task<UploadOutcome, Never>] = [:]
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainTask: Swift::Task<Void, Never>?
    /// The delayed re-queueing of each upload that is waiting to be retried after a failed attempt.
    private var retryTasks: [PersistentIdentifier: Swift::Task<Void, Never>] = [:]
    /// How often each upload has failed during this launch; forgotten once it succeeds or is discarded.
    private var failedAttempts: [PersistentIdentifier: Int] = [:]

    private(set) var categories: Set<Category>

    /// The database in which the module keeps track of its pending uploads.
    ///
    /// `nil` if the database couldn't be opened during the current launch; in that case the module is inert until the next launch.
    nonisolated private let modelContainer: Result<ModelContainer, any Error>
    
    private var modelContext: ModelContext? {
        modelContainer.value?.mainContext
    }

    /// A `Progress` instance representing each category's upload progress,
    /// i.e. the progress of uploading the category's submitted files into the Firebase Storage.
    ///
    /// A category is present in here iff it currently has uploads that are scheduled or being processed during this launch;
    /// uploads that failed (and are waiting to be retried on a subsequent launch) get removed from the progress upon failing.
    @MainActor private(set) var progressByCategory: [Category: Progress] = [:]

    /// Creates a new instance of the `ManagedFileUpload` module.
    ///
    /// Even though it is allowed to schedule uploads for categories not specified when initially creating the module (via the `categories` parameter),
    /// it is strongly recommended that all expected categories be specified here.
    /// The reason for this is that the module will use this initial list of categories to migrate any pending uploads
    /// that were created by the old, file-system-based version of this module.
    ///
    /// - parameter configuration: Where the module keeps its state and how it performs its uploads.
    /// - parameter categories: A list of well-known ``Category`` definitions.
    convenience init( // swiftlint:disable:this function_default_parameter_at_end
        configuration: Configuration = Configuration(),
        @ArrayBuilder<Category> categories: () -> [Category]
    ) {
        self.init(categories: categories(), configuration: configuration)
    }

    init(categories: [Category], configuration config: Configuration) {
        self.categories = Set(categories)
        self.configuration = config
        Self.ensureDirectoriesExist(for: config, using: FileManager())
        self.modelContainer = Result {
            let databaseUrl = config.databaseDirectory.appending(component: "db.sqlite", directoryHint: .notDirectory)
            let modelConfig = if config.isStoredInMemoryOnly {
                ModelConfiguration("ManagedFileUpload", schema: Schema(versionedSchema: SchemaV1.self), isStoredInMemoryOnly: true)
            } else {
                ModelConfiguration("ManagedFileUpload", schema: Schema(versionedSchema: SchemaV1.self), url: databaseUrl)
            }
            return try ModelContainer(
                for: Schema(versionedSchema: SchemaV1.self),
                migrationPlan: MigrationPlan.self,
                configurations: [modelConfig]
            )
        }
    }

    func configure() {
        switch modelContainer {
        case .success:
            break
        case .failure(let error):
            logger.warning("Unable to open pending-uploads database; file uploading is disabled for this launch: \(error)")
            return
        }
        Self.ensureDirectoriesExist(for: configuration, using: fileManager)
        migrateLegacyFileBasedUploads()
        deleteOrphanedStagingFiles()
        // Resume everything that's still pending from previous launches (incl. any just-migrated entries).
        // Routed through `resumePendingUploads()` rather than a bare fetch-and-yield, so that the account-cleanup
        // gate is applied on the one path where it matters most: a launch following a logout whose cleanup didn't finish.
        Swift::Task { [weak self] in
            await self?.resumePendingUploads()
        }
        // Also re-queue the backlog whenever the app returns to the foreground, so that entries which used up their
        // in-launch retries while the app was in the background get another go without waiting for the next launch.
        // (Re-queueing is idempotent, so the overlap with the resume above on a foreground launch is harmless.)
        lifecycle.onChange(of: \.scenePhase) { [weak self] oldValue, newValue in
            guard oldValue != .active, newValue == .active else {
                return
            }
            Swift::Task { @MainActor in
                await self?.resumePendingUploads()
            }
        }
        registerBackgroundTask()
    }

    /// Registers the background task that drains the backlog on devices which are rarely opened.
    ///
    /// Network-only, deliberately without `requiresExternalPower`: the files are small, compressed payloads, and waiting
    /// for a charger is what turns "eventually" into days on devices that are only ever topped up briefly.
    private func registerBackgroundTask() {
        do {
            try backgroundTasks.register(.processing(
                id: .fileUpload,
                nextTriggerDate: .after(TimeConstants.hour * 6),
                options: [.requiresNetworkConnectivity]
            ) { [weak self] in
                await self?.drainPendingUploads()
            })
        } catch {
            logger.error("Failed to register \(MHCBackgroundTasks.TaskIdentifier.fileUpload) background task: \(error)")
        }
    }

    func isActive(_ category: Category) -> Bool {
        progressByCategory[category] != nil
    }

    /// The total on-disk size, in bytes, of all files pending upload within the specified category.
    func totalPendingFileSize(for category: Category) -> Int64? {
        guard let modelContext else {
            return nil
        }
        let categoryId = category.id
        guard let uploads = try? modelContext.fetch(
            FetchDescriptor<ScheduledUpload>(predicate: #Predicate { $0.categoryId == categoryId })
        ) else {
            return nil
        }
        var total: Int64 = 0
        for upload in uploads {
            let url = stagingUrl(forUploadWithId: upload.id)
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}


// MARK: On-disk locations

extension ManagedFileUpload {
    nonisolated var stagingDirectory: URL {
        configuration.directory.appending(component: "staging", directoryHint: .isDirectory)
    }

    /// Creates the module's directories if needed, and excludes them from device backups.
    ///
    /// Both directories hold un-uploaded participant data (the staged payloads themselves, and the index describing
    /// them), which must not end up in an iCloud or Finder backup. Marking the *directories* rather than the individual
    /// files means the flag also covers files created later, and survives SQLite recreating its `-wal`/`-shm` sidecars.
    /// Re-stamping on every launch makes it self-healing.
    nonisolated private static func ensureDirectoriesExist(for configuration: Configuration, using fileManager: FileManager) {
        for url in [configuration.directory, configuration.databaseDirectory] {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                continue
            }
            var url = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? url.setResourceValues(resourceValues)
        }
        let stagingDirectory = configuration.directory.appending(component: "staging", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    /// Where the file belonging to a ``ScheduledUpload`` is staged.
    ///
    /// Named after the entry's id rather than the file's remote name, which is what makes local collisions
    /// impossible without any locking or renaming; the remote name lives in the entry's `filename`.
    nonisolated private func stagingUrl(forUploadWithId id: UUID) -> URL {
        stagingDirectory.appending(component: id.uuidString, directoryHint: .notDirectory)
    }
}


// MARK: Categories

extension ManagedFileUpload {
    struct Category: Identifiable, Hashable, Sendable {
        let id: String
        let firebasePath: String
        let title: LocalizedStringResource

        /// Creates a new Category
        ///
        /// - parameter id: Unique identifier for this category.
        /// - parameter title: User-visible title to be used with uploads in this category
        /// - parameter firebasePath: The folder, relative to the user's directory in the storage bucket, where files uploaded for this category should be stored.
        init(id: String, title: LocalizedStringResource, firebasePath: String) {
            self.id = id
            self.title = title
            self.firebasePath = firebasePath
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    /// Resolves a ``ScheduledUpload``'s category information into a ``Category``,
    /// preferring the matching currently-registered category, if it exists.
    private func resolveCategory(id: String, firebasePath: String) -> Category {
        categories.first { $0.id == id } ?? Category(id: id, title: "\(id)", firebasePath: firebasePath)
    }

    func register(_ category: Category) {
        categories.insert(category)
    }
}


// MARK: Progress Tracking

extension ManagedFileUpload {
    /// Counts a newly-scheduled (or newly-resumed) upload into its category's progress.
    ///
    /// This happens when the upload is enqueued (rather than when it starts getting processed),
    /// so that the progress' total reflects the full queue depth instead of just the currently-in-flight uploads.
    /// Every enqueued upload is matched by exactly one ``completeUploadProgress(for:)`` or
    /// ``abortUploadProgress(for:)`` in `finishUpload(_:category:outcome:)`, on every path.
    private func addUploadToProgress(for category: Category) {
        if let progress = progressByCategory[category] {
            progress.totalUnitCount += 1
        } else {
            let progress = Progress(totalUnitCount: 1)
            progress.localizedDescription = String(localized: category.title)
            progressByCategory[category] = progress
        }
    }

    private func completeUploadProgress(for category: Category) {
        guard let progress = progressByCategory[category] else {
            return
        }
        progress.completedUnitCount += 1
        if progress.completedUnitCount >= progress.totalUnitCount {
            progressByCategory[category] = nil
        }
    }

    /// Drops all recorded progress, e.g. because everything pending has just been cleared.
    private func resetAllProgress() {
        progressByCategory.removeAll()
    }

    /// Drops the recorded progress for a single category.
    private func resetProgress(for category: Category) {
        progressByCategory[category] = nil
    }

    /// Un-counts a failed or discarded upload from its category's progress, so that the category doesn't appear active forever.
    private func abortUploadProgress(for category: Category) {
        guard let progress = progressByCategory[category] else {
            return
        }
        progress.totalUnitCount -= 1
        if progress.totalUnitCount <= 0 || progress.completedUnitCount >= progress.totalUnitCount {
            progressByCategory[category] = nil
        }
    }
}


// MARK: Firebase

extension StorageReference {
    /// Uploads a file, and actually stops when the surrounding task is cancelled.
    ///
    /// `putFileAsync` wraps the callback API in a bare `withCheckedThrowingContinuation`, with no cancellation
    /// handler — so cancelling the task neither stops the transfer nor resumes the caller. That matters here because
    /// cancellation is how the module stops work before wiping an account's data, and how a background task's
    /// expiration stops a transfer that would otherwise be killed by the watchdog.
    ///
    /// The original error is propagated unchanged, so that callers can distinguish an offline failure from a quota or
    /// permission failure by its `NSError` domain and code.
    fileprivate func putFileRespectingCancellation(
        from url: URL,
        metadata: StorageMetadata
    ) async throws {
        let cancellation = ManagedFileUpload.StorageUploadCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = putFile(from: url, metadata: metadata) { metadata, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if metadata == nil {
                        continuation.resume(throwing: ManagedFileUpload.StorageUploadError.missingUploadMetadata)
                    } else {
                        continuation.resume()
                    }
                }
                cancellation.install(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}


extension ManagedFileUpload {
    fileprivate enum StorageUploadError: Error, Sendable {
        case missingUploadMetadata
    }
    
    fileprivate final class StorageUploadCancellation: Sendable {
        private struct State {
            var isCancelled = false
            var task: StorageUploadTask?
        }

        private let state = Mutex(State())

        func install(_ task: StorageUploadTask) {
            let shouldCancel = state.withLock { state in
                guard !state.isCancelled else {
                    return true
                }
                state.task = task
                return false
            }
            if shouldCancel {
                task.cancel()
            }
        }

        func cancel() {
            let task = state.withLock { state in
                state.isCancelled = true
                let task = state.task
                state.task = nil
                return task
            }
            task?.cancel()
        }
    }
    
    /// Uploads a staged file into the owning account's directory in the Firebase Storage.
    ///
    /// - Note: only ever called when no `uploadOperation` was injected — `Storage.storage()` force-unwraps
    ///     `FirebaseApp.app()`, so merely mentioning it is unsafe in a context where firebase isn't configured.
    @concurrent
    private func uploadToFirebaseStorage(
        at fileUrl: URL,
        category: Category,
        accountId: String,
        filename: String,
        metadata: [String: String]
    ) async throws {
        let storageRef = Storage.storage().reference(withPath: "users/\(accountId)/\(category.firebasePath)/\(filename)")
        let bucket = storageRef.bucket
        let path = storageRef.fullPath
        await logger.notice("uploading to \(bucket):\(path)")
        let storageMetadata = StorageMetadata()
        storageMetadata.contentType = "application/octet-stream"
        if !metadata.isEmpty {
            storageMetadata.customMetadata = metadata
        }
        try await storageRef.putFileRespectingCancellation(from: fileUrl, metadata: storageMetadata)
    }
}


// MARK: Migration

extension ManagedFileUpload {
    /// Migrates pending uploads that were created by the old, file-system-based version of this module into the database.
    ///
    /// The old module tracked its pending uploads as files in one directory per category (within the module's directory),
    /// stored under their remote filenames.
    /// We turn every such file into a ``ScheduledUpload`` entry and move it into the staging directory.
    /// This is a one-time migration in the sense that it moves the files out of the legacy directories as it processes them;
    /// on all subsequent launches there's simply nothing left to migrate.
    ///
    /// - Note: the resulting entries carry no `accountId`: this runs during `configure()`, before firebase has restored
    ///     the session, so there is nobody to attribute them to yet. They are adopted by the signed-in account when
    ///     they are first uploaded — see `resolveOwner(of:in:)`.
    private func migrateLegacyFileBasedUploads() {
        guard let modelContext else {
            return
        }
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        let pendingMoves: [(srcUrl: URL, upload: ScheduledUpload)] = categories.reduce(into: []) { result, category in
            // construct the URL exactly the way the old module did, so that we look for the files where it put them.
            let legacyDir = configuration.directory.appending(component: category.id, directoryHint: .isDirectory)
            guard fileManager.isDirectory(at: legacyDir) else {
                return
            }
            for url in (try? fileManager.contents(of: legacyDir)) ?? [] where !fileManager.isDirectory(at: url) {
                let upload = ScheduledUpload(
                    id: UUID(),
                    category: category,
                    filename: url.lastPathComponent,
                    metadata: [:],
                    accountId: nil,
                    accountDataGeneration: accountDataGeneration
                )
                modelContext.insert(upload)
                result.append((url, upload))
            }
        }
        if !pendingMoves.isEmpty {
            do {
                // save all entries in a single commit, before moving any files: a database entry without a file resolves itself
                // (it simply gets discarded, and the still-in-place file gets re-migrated on the next launch),
                // whereas a moved file without an entry would be deleted by the orphan sweep.
                try modelContext.save()
            } catch {
                logger.error("Unable to migrate pending uploads: \(error)")
                modelContext.rollback()
                return
            }
            var anyMovesFailed = false
            for (srcUrl, upload) in pendingMoves {
                do {
                    try fileManager.moveItem(at: srcUrl, to: stagingUrl(forUploadWithId: upload.id))
                } catch {
                    logger.error("Unable to migrate pending upload at \(srcUrl): \(error)")
                    modelContext.delete(upload)
                    anyMovesFailed = true
                }
            }
            if anyMovesFailed {
                try? modelContext.save()
            }
        }
        removeEmptyLegacyDirectories()
    }

    /// Removes any (now-empty) directories left behind by the old file-system-based version of the module.
    ///
    /// Directories that still contain files (i.e., pending uploads belonging to categories that aren't registered with the module)
    /// are intentionally left in place, so that the data can still be migrated in the future.
    private func removeEmptyLegacyDirectories() {
        let children = (try? fileManager.contents(of: configuration.directory)) ?? []
        for url in children where fileManager.isDirectory(at: url) && url.lastPathComponent != stagingDirectory.lastPathComponent {
            if directoryTreeContainsFiles(at: url) {
                logger.warning("Found unmigrated pending uploads at \(url.path); leaving them in place.")
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    nonisolated private func directoryTreeContainsFiles(at url: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        return enumerator.lazy
            .compactMap { $0 as? URL }
            .contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
    }

    /// Deletes any files in the staging directory that don't belong to a ``ScheduledUpload`` entry.
    ///
    /// Such files can come into existence when the app gets terminated after an upload's database entry was deleted, but before its file was.
    private func deleteOrphanedStagingFiles() {
        guard let modelContext, let uploads = try? modelContext.fetch(FetchDescriptor<ScheduledUpload>()) else {
            // if we can't read the database, we can't tell which files are orphaned. leave everything in place.
            return
        }
        let validNames = Set(uploads.map { $0.id.uuidString })
        for url in (try? fileManager.contents(of: stagingDirectory)) ?? [] where !validNames.contains(url.lastPathComponent) {
            logger.notice("Deleting orphaned staging file at \(url.lastPathComponent)")
            try? fileManager.removeItem(at: url)
        }
    }
}


// MARK: Model

extension ManagedFileUpload {
    /// The current version of the ``ScheduledUpload`` schema.
    private enum SchemaV1: VersionedSchema {
        nonisolated static var versionIdentifier: Schema.Version {
            Schema.Version(1, 0, 0)
        }

        nonisolated static var models: [any PersistentModel.Type] {
            [ManagedFileUpload.ScheduledUpload.self]
        }
    }

    /// Migration plan for the pending-uploads store.
    ///
    /// Every future column addition becomes one additional ``VersionedSchema`` plus a `MigrationStage.lightweight`
    /// entry here; without a plan, ordinary schema evolution would instead surface as a failure to open the store.
    private enum MigrationPlan: SchemaMigrationPlan {
        nonisolated static var schemas: [any VersionedSchema.Type] {
            [SchemaV1.self]
        }

        nonisolated static var stages: [MigrationStage] {
            []
        }
    }

    /// A pending upload, i.e. a file that has been handed to the module but hasn't been uploaded yet.
    @Model
    fileprivate final class ScheduledUpload {
        @Attribute(.unique)
        private(set) var id = UUID()

        /// The id of the ``ManagedFileUpload/Category`` within which the file should be uploaded.
        private(set) var categoryId: String
        /// The category's remote folder, denormalized into the entry so that the upload can still be
        /// performed if the category isn't registered with the module anymore.
        private(set) var categoryFirebasePath: String
        /// The name under which the file should be uploaded, within the category's remote folder.
        private(set) var filename: String
        /// Custom metadata that should be associated with the file, via the firebase storage metadata API.
        private(set) var metadata: [String: String]
        /// When the upload was scheduled.
        private(set) var creationDate = Date()

        /// The id of the account this file was collected for, and into whose storage directory it must be uploaded.
        ///
        /// Captured when the upload is staged, rather than read at upload time: an upload that outlives a logout
        /// must never end up in the next participant's directory.
        /// `nil` only for entries created by the one-time migration from the old, file-system-based module,
        /// which runs before firebase has restored the session and therefore cannot know the account.
        var accountId: String?
        /// The value of `LocalPreferenceKeys.accountDataGeneration` at the time the upload was staged.
        ///
        /// Recorded for diagnostics; uploads are not gated on it (``accountId`` answers the question that matters,
        /// and a log-out-then-log-in as the same user bumps the generation without changing the owner).
        var accountDataGeneration: Int = 0

        /// The number of times the app already initiated an upload for this file.
        var numAttempts = 0

        init(
            id: UUID,
            category: Category,
            filename: String,
            metadata: [String: String],
            accountId: String?,
            accountDataGeneration: Int
        ) {
            self.id = id
            self.categoryId = category.id
            self.categoryFirebasePath = category.firebasePath
            self.filename = filename
            self.metadata = metadata
            self.accountId = accountId
            self.accountDataGeneration = accountDataGeneration
        }
    }


    /// A ``ScheduledUpload`` snapshot that can be handed across isolation domains.
    ///
    /// SwiftData models are bound to the context that fetched them; the queue only ever needs the identifier
    /// and the category information, so we copy those out instead of keeping the model objects alive.
    private struct PendingUpload: Sendable, Hashable {
        let persistentId: PersistentIdentifier
        let categoryId: String
        let categoryFirebasePath: String
    }
}


extension ModelContext {
    func existingModel<T: PersistentModel>(for id: PersistentIdentifier) -> T? {
        if let model: T = self.registeredModel(for: id) {
            return model
        }
        let descriptor = FetchDescriptor<T>(
            predicate: #Predicate { $0.persistentModelID == id }
        )
        return (try? self.fetch(descriptor))?.first
    }
}


// MARK: Queue + Draining

extension ManagedFileUpload {
    /// Starts the loop that performs the queued uploads, at most `maximumConcurrentUploads` at a time.
    ///
    /// Started from `configure()` rather than from a `ServiceModule`'s `run()`, so that it also runs on launches
    /// that never connect a scene. The stream is never finished, so the task must not keep the module alive.
    private func startDrainingIfNeeded() {
        guard drainTask == nil else {
            return
        }
        let stream = newUploads.stream
        let limit = configuration.maximumConcurrentUploads
        drainTask = Swift::Task { [weak self] in
            await withManagedTaskQueue(limit: limit) { taskQueue in
                for await uploadId in stream {
                    taskQueue.addTask { [weak self] in
                        await self?.performUpload(uploadId)
                    }
                }
            }
        }
    }

    /// Hands an upload to the queue, counting it into its category's progress.
    ///
    /// Ignored if the queue is closed, or if this upload is already in flight.
    private func enqueue(_ uploadId: PersistentIdentifier, category: Category) {
        guard acceptsUploads, enqueuedUploads[uploadId] == nil else {
            return
        }
        // Being queued now supersedes any retry that was still waiting for its delay to pass.
        retryTasks.removeValue(forKey: uploadId)?.cancel()
        enqueuedUploads[uploadId] = category
        addUploadToProgress(for: category)
        newUploads.continuation.yield(uploadId)
    }

    private func performUpload(_ uploadId: PersistentIdentifier) async {
        guard acceptsUploads, let modelContainer = modelContainer.value, activeUploads[uploadId] == nil else {
            // The queue was closed (or the store is gone) between this upload being enqueued and picked up.
            // Its entry survives; a later `resumePendingUploads()` or the next launch will retry it.
            finishUpload(uploadId, outcome: .failed)
            return
        }
        let task = Swift::Task { [weak self] in
            await self?.upload(uploadId, in: modelContainer) ?? .failed
        }
        activeUploads[uploadId] = task
        let outcome = await task.value
        finishUpload(uploadId, outcome: outcome)
    }

    /// The single balanced exit for every enqueued upload, on every path.
    private func finishUpload(_ uploadId: PersistentIdentifier, outcome: UploadOutcome) {
        activeUploads[uploadId] = nil
        if let category = enqueuedUploads.removeValue(forKey: uploadId) {
            switch outcome {
            case .completed:
                failedAttempts[uploadId] = nil
                completeUploadProgress(for: category)
            case .failed:
                abortUploadProgress(for: category)
                scheduleRetry(uploadId, category: category)
            case .discarded:
                failedAttempts[uploadId] = nil
                abortUploadProgress(for: category)
            }
        }
        signalQuiescenceIfIdle()
    }

    /// Re-queues a failed upload after a delay that grows with the number of failures, as long as the configuration allows.
    ///
    /// Deliberately invisible to ``waitUntilQuiescent()``: a background task that drains the queue should report completion
    /// once every entry has had its attempt, not sit through the backoff of the ones that failed.
    private func scheduleRetry(_ uploadId: PersistentIdentifier, category: Category) {
        guard acceptsUploads else {
            // The queue was closed (a clear, or the drain being cancelled); whoever reopens it also resumes the backlog.
            return
        }
        let attempts = failedAttempts[uploadId, default: 0] + 1
        failedAttempts[uploadId] = attempts
        guard let delay = configuration.retryDelay(attempts) else {
            // Left for the next resume: the next foregrounding, the module's background task, or the next launch.
            return
        }
        retryTasks[uploadId]?.cancel()
        retryTasks[uploadId] = Swift::Task { [weak self] in
            try? await Swift::Task.sleep(for: delay)
            guard !Swift::Task.isCancelled, let self else {
                return
            }
            self.retryTasks[uploadId] = nil
            self.enqueue(uploadId, category: category)
        }
    }
}


// MARK: Queue + Quiescence

extension ManagedFileUpload {
    /// Waits until every accepted upload has finished one attempt.
    func waitUntilQuiescent() async {
        guard !enqueuedUploads.isEmpty || !activeUploads.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    /// Closes the queue, cancels every in-flight upload, and waits for them to actually stop.
    ///
    /// Every destructive operation sits on this: it is what makes "no upload is touching the staged files or the
    /// database" true, rather than merely likely. Closing the queue first is what makes the wait terminate — uploads
    /// that were enqueued but not yet started hit the closed-queue check in `performUpload(_:)` and finish immediately,
    /// and nothing new can be added behind our back.
    func cancelAndWaitForQuiescence() async {
        acceptsUploads = false
        for task in retryTasks.values {
            task.cancel()
        }
        retryTasks.removeAll()
        for task in activeUploads.values {
            task.cancel()
        }
        await waitUntilQuiescent()
    }

    private func signalQuiescenceIfIdle() {
        guard enqueuedUploads.isEmpty, activeUploads.isEmpty else {
            return
        }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}


// MARK: Queue + Resuming

extension ManagedFileUpload {
    /// Re-queues every upload that is still pending, and re-opens the queue if it was closed.
    ///
    /// Returns once the pending uploads have been queued — *not* once they have been uploaded. Callers await this
    /// as part of handling an account association, so anything slower than that would stall every login behind the
    /// entire backlog.
    func resumePendingUploads() async {
        // Unconditionally first, before any gate: every early return below must still leave the queue open.
        // (A clear that is followed by a resume which bails out — nobody signed in yet, cleanup still pending —
        // would otherwise leave the queue closed for the rest of the launch.)
        acceptsUploads = true
        startDrainingIfNeeded()
        guard let modelContainer = modelContainer.value else {
            return
        }
        guard !configuration.isCleanupPending() else {
            logger.notice("Not resuming pending uploads while cleanup from the previous account is pending")
            return
        }
        guard let accountId = await currentAccountId(), !accountId.isEmpty else {
            return
        }
        for pending in await loadPendingUploads(from: modelContainer) {
            enqueue(
                pending.persistentId,
                category: resolveCategory(id: pending.categoryId, firebasePath: pending.categoryFirebasePath)
            )
        }
    }

    /// Re-queues the whole backlog and waits until every entry has had one attempt.
    ///
    /// This is what the module's own background task runs. Cancelling the calling task — which is what a background task's
    /// expiration does — stops the in-flight uploads (their entries survive for a later attempt) and reopens the queue.
    func drainPendingUploads() async {
        await resumePendingUploads()
        await withTaskCancellationHandler {
            await waitUntilQuiescent()
        } onCancel: {
            Swift::Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.cancelAndWaitForQuiescence()
                self.acceptsUploads = true
            }
        }
    }

    /// Snapshots the pending uploads on a throwaway background context.
    ///
    /// Deliberately not the `mainContext`: fetching there would register every pending model object for the lifetime
    /// of the process, which is the one place a large backlog could turn into a launch-time memory problem.
    @concurrent
    private func loadPendingUploads(from container: ModelContainer) async -> [PendingUpload] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ScheduledUpload>(sortBy: [SortDescriptor(\.creationDate)])
        guard let uploads = try? context.fetch(descriptor) else {
            return []
        }
        return uploads.map {
            PendingUpload(
                persistentId: $0.persistentModelID,
                categoryId: $0.categoryId,
                categoryFirebasePath: $0.categoryFirebasePath
            )
        }
    }
}


// MARK: Performing a single upload

extension ManagedFileUpload {
    @concurrent
    private func upload(_ uploadId: PersistentIdentifier, in container: ModelContainer) async -> UploadOutcome {
        let context = ModelContext(container)
        guard let upload: ScheduledUpload = context.existingModel(for: uploadId) else {
            // The entry was cleared between being queued and being picked up.
            return .discarded
        }
        let fileUrl = stagingUrl(forUploadWithId: upload.id)
        guard let owner = await validatedOwner(of: upload, at: fileUrl, in: context) else {
            return .discarded
        }
        return await transfer(upload, at: fileUrl, owner: owner, in: context)
    }

    /// Checks that the upload can still legitimately be performed, dropping its entry if it cannot.
    ///
    /// - returns: the owning account id, or `nil` if the entry was discarded.
    @concurrent
    private func validatedOwner(
        of upload: ScheduledUpload,
        at fileUrl: URL,
        in context: ModelContext
    ) async -> String? {
        guard fileManager.fileExists(atPath: fileUrl.path(percentEncoded: false)) else {
            // `stage(...)` moves the file into place before it commits the entry, so an entry whose file is gone has
            // genuinely lost it (a partially failed clear, or something outside the module deleting it); nothing can bring it back.
            await logger.error("Discarding scheduled upload \(upload.id): its staged file is missing.")
            context.delete(upload)
            try? context.save()
            return nil
        }
        guard let owner = await resolveOwner(of: upload, in: context) else {
            let filename = upload.filename
            let categoryId = upload.categoryId
            let size = (try? fileUrl.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            // Uploading it under the current account would deposit the previous participant's data in the new
            // participant's directory; keeping it would retain that data on the device indefinitely. Log enough
            // for the loss to be observable, then drop it.
            await logger.error("""
                Discarding scheduled upload \(upload.id) ('\(filename)', category '\(categoryId)', \(size) bytes): \
                it belongs to a different account.
                """)
            context.delete(upload)
            try? context.save()
            try? fileManager.removeItem(at: fileUrl)
            return nil
        }
        return owner
    }

    @concurrent
    private func transfer(
        _ upload: ScheduledUpload,
        at fileUrl: URL,
        owner: String,
        in context: ModelContext
    ) async -> UploadOutcome {
        let category = await resolveCategory(id: upload.categoryId, firebasePath: upload.categoryFirebasePath)
        let filename = upload.filename
        let customMetadata = upload.metadata
        upload.numAttempts += 1
        try? context.save()
        do {
            if let uploadOperation = configuration.uploadOperation {
                // Checked before touching any Firebase symbol: `Storage.storage()` force-unwraps `FirebaseApp.app()`,
                // and the unit test host launches with firebase disabled.
                try await uploadOperation(fileUrl, category, owner, filename, customMetadata)
            } else {
                try await uploadToFirebaseStorage(
                    at: fileUrl,
                    category: category,
                    accountId: owner,
                    filename: filename,
                    metadata: customMetadata
                )
            }
        } catch {
            if !Swift::Task.isCancelled {
                await logger.error("Upload of '\(filename)' failed: \(error)")
            }
            return .failed
        }
        // The transfer succeeded, so the entry is done regardless of whether we were cancelled in the meantime;
        // dropping it here is what keeps a cancelled drain from re-uploading the same bytes on the next launch.
        context.delete(upload)
        try? context.save()
        do {
            try fileManager.removeItem(at: fileUrl)
        } catch {
            // Not a problem: the file is orphaned now that its entry is gone, and the next launch's sweep removes it.
            await logger.error("Unable to delete uploaded file at \(fileUrl.lastPathComponent): \(error)")
        }
        return .completed
    }

    /// Determines which account's storage directory this upload belongs in.
    ///
    /// - returns: the owning account id, or `nil` if the upload must not be performed right now.
    @concurrent
    private func resolveOwner(of upload: ScheduledUpload, in context: ModelContext) async -> String? {
        guard let accountId = await currentAccountId(), !accountId.isEmpty else {
            return nil
        }
        guard let owner = upload.accountId else {
            // An entry created by the one-time migration from the old, file-system-based module. It carries no owner
            // because that migration runs before firebase has restored the session. Adopt it for the current account,
            // but only while the app isn't telling us that data from a previous account may still be lying around —
            // which is precisely what `pendingAccountDataCleanupRequired` means.
            guard !configuration.isCleanupPending() else {
                return nil
            }
            upload.accountId = accountId
            try? context.save()
            return accountId
        }
        return owner == accountId ? owner : nil
    }

    /// The id of the currently signed-in account, or `nil` if there isn't one.
    @concurrent
    private func currentAccountId() async -> String? {
        if let accountIdProvider = configuration.accountIdProvider {
            return await accountIdProvider()
        }
        return await MainActor.run {
            // `signedIn` matters as well as the details being present: the details linger for a moment after a
            // sign-out, and an empty id would produce the path `users//…`, which no storage rule protects.
            guard let account, account.signedIn, let accountId = account.details?.accountId, !accountId.isEmpty else {
                return nil
            }
            return accountId
        }
    }
}


// MARK: Staging

extension ManagedFileUpload {
    /// Takes ownership of the file at `url` and schedules it for upload.
    ///
    /// The file will be uploaded to `users/{accountId}/{category.firebasePath}/{url.lastPathComponent}` in the Firebase
    /// Storage — the remote object name is always exactly the caller's `lastPathComponent`, which callers such as the
    /// SensorKit uploader rely on when they record a reference to the file before it has been uploaded.
    ///
    /// This function returns once the upload has been durably scheduled; the upload itself happens asynchronously,
    /// and, if it cannot be completed during the current launch of the app, will be retried on subsequent launches.
    ///
    /// - parameter accountDataGeneration: the generation the caller staged this data under; defaults to the current one.
    ///     Passing the value the caller captured when it started collecting closes the window where data collected for
    ///     one account is staged after the app has moved on to another.
    @concurrent
    func stage(
        _ url: URL,
        category: Category,
        accountDataGeneration: Int? = nil,
        metadata: [String: String] = [:]
    ) async throws {
        let generation = accountDataGeneration ?? LocalPreferencesStore.standard[.accountDataGeneration]
        try ensureUploadsAreAllowed(generation)
        guard let accountId = await currentAccountId(), !accountId.isEmpty else {
            throw UploadError.noAccount
        }
        // File first, entry second. A committed entry must always have its file: everything that finds an entry without
        // one (a resume running concurrently on the main actor, the next launch) treats that as a lost file and drops the
        // entry — and returning success from here after that would have the caller delete its only copy of the data.
        // The reverse — a file without an entry, if the process dies in between — is harmless: it's an orphan that the next
        // launch sweeps up, and since we haven't returned, the caller still holds its copy.
        let uploadId = UUID()
        let stagingUrl = stagingUrl(forUploadWithId: uploadId)
        try fileManager.moveItem(at: url, to: stagingUrl)
        let persistentId: PersistentIdentifier
        do {
            persistentId = try await commitUpload(
                id: uploadId,
                filename: url.lastPathComponent,
                category: category,
                metadata: metadata,
                accountId: accountId,
                accountDataGeneration: generation
            )
        } catch {
            try? fileManager.removeItem(at: stagingUrl)
            throw error
        }
        await finishStaging(persistentId, category: category)
    }

    /// Creates and commits the ``ScheduledUpload`` entry for a new upload.
    ///
    /// Runs on the main actor and contains no suspension point, so the gate check and the `save()` cannot be
    /// interleaved with a clear (which is also main-actor bound). That is what makes the guarantee "no entry is ever
    /// committed after the app decided the account's data must go" hold, rather than merely usually hold.
    private func commitUpload( // swiftlint:disable:this function_parameter_count
        id: UUID,
        filename: String,
        category: Category,
        metadata: [String: String],
        accountId: String,
        accountDataGeneration: Int
    ) throws -> PersistentIdentifier {
        try ensureUploadsAreAllowed(accountDataGeneration)
        guard let modelContext else {
            throw UploadError.databaseUnavailable
        }
        register(category)
        let upload = ScheduledUpload(
            id: id,
            category: category,
            filename: filename,
            metadata: metadata,
            accountId: accountId,
            accountDataGeneration: accountDataGeneration
        )
        modelContext.insert(upload)
        try modelContext.save()
        return upload.persistentModelID
    }

    /// Queues a freshly staged upload, if the queue is still open.
    ///
    /// - Important: deliberately does *not* check for cancellation, and never deletes the file. The file is already
    ///     in the module's custody at this point; throwing it away because a background task expired would be a data
    ///     loss path that neither the old file-system-based module nor its callers have any way to recover from
    ///     (the HealthKit anchor has already advanced by then). If the queue is closed, the entry simply stays
    ///     pending and is picked up by the next ``resumePendingUploads()``.
    private func finishStaging(_ uploadId: PersistentIdentifier, category: Category) {
        enqueue(uploadId, category: category)
    }

    /// Whether an upload staged under `accountDataGeneration` may still be committed.
    nonisolated private func uploadsAreAllowed(_ accountDataGeneration: Int) -> Bool {
        // Generation before flag: the writers set the flag first and bump the generation second, so a reader that
        // sees the new generation is guaranteed to also see the flag.
        let preferences = LocalPreferencesStore.standard
        return preferences[.accountDataGeneration] == accountDataGeneration && !configuration.isCleanupPending()
    }

    nonisolated private func ensureUploadsAreAllowed(_ accountDataGeneration: Int) throws {
        try Swift::Task.checkCancellation()
        guard uploadsAreAllowed(accountDataGeneration) else {
            throw UploadError.cancelled
        }
    }
}


// MARK: Clearing

extension ManagedFileUpload {
    /// Deletes all pending uploads, incl. their staged files.
    ///
    /// Idempotent, and safe to call when there is nothing to clear or no database at all: a failure here leaves
    /// `pendingAccountDataCleanupRequired` set, which disables *all* data collection and uploading, so "there was
    /// nothing to do" must never be reported as a failure.
    func clearPendingUploads() async throws {
        await cancelAndWaitForQuiescence()
        defer {
            // Unconditionally reopen, even if something below throws: a closed queue would silently reject every
            // subsequent `stage()` for the rest of the launch.
            acceptsUploads = true
            Self.ensureDirectoriesExist(for: configuration, using: fileManager)
        }
        if let modelContext {
            try modelContext.delete(model: ScheduledUpload.self)
            try modelContext.save()
        }
        resetAllProgress()
        enqueuedUploads.removeAll()
        failedAttempts.removeAll()
        try removeContents(of: stagingDirectory)
        // Also sweep any legacy per-category directories: the migration deliberately leaves behind directories
        // belonging to categories that aren't registered during this launch, and those hold the previous account's
        // data just as much as the staging directory does.
        for url in (try? fileManager.contentsOfDirectory(at: configuration.directory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent != stagingDirectory.lastPathComponent {
            try fileManager.removeItem(at: url)
        }
    }

    /// Deletes all pending uploads within the specified category, incl. their staged files.
    func clearPendingUploads(for category: Category) async throws {
        await cancelAndWaitForQuiescence()
        let result = Result {
            guard let modelContext else {
                return
            }
            let categoryId = category.id
            let uploads = try modelContext.fetch(FetchDescriptor<ScheduledUpload>(predicate: #Predicate { $0.categoryId == categoryId }))
            for upload in uploads {
                let url = stagingUrl(forUploadWithId: upload.id)
                if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: url)
                }
                enqueuedUploads.removeValue(forKey: upload.persistentModelID)
                failedAttempts.removeValue(forKey: upload.persistentModelID)
                modelContext.delete(upload)
            }
            try modelContext.save()
            resetProgress(for: category)
            let legacyDirectory = configuration.directory.appending(component: category.id, directoryHint: .isDirectory)
            if fileManager.isDirectory(at: legacyDirectory) {
                try fileManager.removeItem(at: legacyDirectory)
            }
        }
        // The cancellation also stopped other categories. Requeue every survivor before returning, even if the clear failed.
        Self.ensureDirectoriesExist(for: configuration, using: fileManager)
        await resumePendingUploads()
        try result.get()
    }

    /// Empties a directory entry-by-entry, rather than removing and recreating the directory itself.
    ///
    /// `removeItem` on a non-empty directory can race a concurrent writer and fail with `ENOTEMPTY` — which iOS 26
    /// reports as a misleading "you don't have permission" error, *after* it has already deleted part of the contents.
    /// Removing the entries individually keeps a partial failure partial, and keeps the directory itself in place so
    /// that subsequent staging still works.
    private func removeContents(of directory: URL) throws {
        guard fileManager.isDirectory(at: directory) else {
            return
        }
        var firstError: (any Error)?
        for url in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let fileUpload = Self("edu.stanford.MyHeartCounts.fileUpload")
}
