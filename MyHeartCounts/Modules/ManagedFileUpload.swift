//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseStorage
import Foundation
import Grove
import GroveAccount
import GroveFoundation
import OSLog
import Synchronization


@Observable
@MainActor
final class ManagedFileUpload: Module, EnvironmentAccessible, Sendable {
    nonisolated private static let directory = URL.documentsDirectory.appending(component: "ManagedFileUploading", directoryHint: .isDirectory)
    nonisolated private static let maximumConcurrentUploads = 2

    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    // swiftlint:enable attributes

    private(set) var categories: Set<Category>
    nonisolated(unsafe) private let fileManager = FileManager()
    nonisolated private let stagingLock = Mutex(())
    nonisolated private let directory: URL
    nonisolated private let accountIdProvider: (@Sendable () async -> String?)?
    nonisolated private let uploadOperation: (@Sendable (URL, Category, String) async throws -> Void)?
    nonisolated private let isCleanupPending: @Sendable () -> Bool

    @ObservationIgnored private var orphanReplayTask: Task<Void, Never>?
    @ObservationIgnored private var replayGeneration: UInt = 0
    @ObservationIgnored private lazy var uploadQueue = UploadQueue(maximumConcurrentUploads: Self.maximumConcurrentUploads) { [weak self] upload in
        guard let self else {
            return
        }
        await self.uploadAndDelete(upload)
    }

    /// A `Progress` instance representing each category's upload progress,
    /// i.e. the progress of uploading the category's submitted files into the Firebase Storage.
    @MainActor private(set) var progressByCategory: [Category: Progress] = [:]

    /// Creates a new instance of the `ManagedFileUpload` module.
    ///
    /// Even though it is allowed to schedule uploads for categories not specified when initially creating the module (via the `categories` parameter),
    /// it is strongly recommended that all expected categories be specified here.
    /// The reason for this is that the module will use this initial list of categories to resume any pending uploads that remain from previous launches of the app.
    ///
    /// - parameter categories: A list of well-known ``Category`` definitions.
    init(@ArrayBuilder<Category> categories: () -> [Category]) {
        self.categories = Set(categories())
        self.directory = Self.directory
        self.accountIdProvider = nil
        self.uploadOperation = nil
        self.isCleanupPending = {
            LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired]
        }
    }

    init(
        categories: [Category],
        directory: URL,
        accountIdProvider: @escaping @Sendable () async -> String?,
        uploadOperation: @escaping @Sendable (URL, Category, String) async throws -> Void,
        isCleanupPending: @escaping @Sendable () -> Bool = {
            LocalPreferencesStore.standard[.pendingAccountDataCleanupRequired]
        }
    ) {
        self.categories = Set(categories)
        self.directory = directory
        self.accountIdProvider = accountIdProvider
        self.uploadOperation = uploadOperation
        self.isCleanupPending = isCleanupPending
    }

    func configure() {
        startPendingUploadReplay()
    }

    func isActive(_ category: Category) -> Bool {
        progressByCategory[category] != nil
    }
}


extension ManagedFileUpload {
    /// Cancels replay and waits for active uploads to stop.
    func cancelAndWaitForQuiescence() async {
        replayGeneration &+= 1
        orphanReplayTask?.cancel()
        let replayTask = orphanReplayTask
        orphanReplayTask = nil

        let uploadQueue = uploadQueue
        await replayTask?.value
        await uploadQueue.pauseAndCancel()
    }

    func clearPendingUploads() async throws {
        await cancelAndWaitForQuiescence()
        if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: directory)
        }
        await uploadQueue.resume()
    }

    func clearPendingUploads(for category: Category) async throws {
        await cancelAndWaitForQuiescence()
        try removeStagedFiles(for: category)
        await resumePendingUploads()
    }

    /// Waits for every accepted file to complete one upload attempt.
    func waitUntilQuiescent() async {
        await uploadQueue.waitUntilQuiescent()
    }

    nonisolated
    private func removeStagedFiles(for category: Category) throws {
        let categoryDirectory = stagingDirectory(for: category)
        if fileManager.fileExists(atPath: categoryDirectory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: categoryDirectory)
        }
    }
}


extension ManagedFileUpload {
    struct Category: Identifiable, Hashable, Sendable {
        let id: String
        let firebasePath: String
        let title: LocalizedStringResource
        let stagingDirUrl: URL

        /// Creates a new Category
        ///
        /// - parameter id: Unique identifier for this category.
        /// - parameter title: User-visible title to be used with uploads in this category
        /// - parameter firebasePath: The folder, relative to the user's directory in the storage bucket, where files uploaded for this category should be stored.
        init(id: String, title: LocalizedStringResource, firebasePath: String) { // swiftlint:disable:this function_default_parameter_at_end
            self.id = id
            self.title = title
            self.firebasePath = firebasePath
            self.stagingDirUrl = ManagedFileUpload.directory.appending(component: id, directoryHint: .isDirectory)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
}


extension ManagedFileUpload {
    enum UploadError: Error, Sendable {
        case noAccount
        case cancelled
    }

    /// Moves a file into durable staging and schedules its upload.
    ///
    /// Files left in staging are retried on the next launch.
    @concurrent
    func stage(
        _ url: URL,
        category: Category,
        accountDataGeneration: Int? = nil
    ) async throws {
        let accountDataGeneration = accountDataGeneration
            ?? LocalPreferencesStore.standard[.accountDataGeneration]
        try ensureUploadsAreAllowed(accountDataGeneration)
        guard let accountId = await currentAccountId(), !accountId.isEmpty else {
            throw UploadError.noAccount
        }
        let uploadQueue = await uploadQueue
        guard let queueGeneration = await uploadQueue.reservation() else {
            throw UploadError.cancelled
        }
        await registerCategory(category)
        let stagingDirectory = stagingDirectory(for: category)
        try createDirectoryIfNeeded(at: stagingDirectory)
        try ensureUploadsAreAllowed(accountDataGeneration)
        let stagingUrl = try moveToStaging(url, in: stagingDirectory)
        let upload = PendingUpload(fileUrl: stagingUrl, category: category, accountId: accountId)
        guard await uploadQueue.enqueue(
            upload,
            generation: queueGeneration
        ) else {
            try? fileManager.removeItem(at: stagingUrl)
            throw UploadError.cancelled
        }
    }

    nonisolated private func ensureUploadsAreAllowed(_ accountDataGeneration: Int) throws {
        try Task.checkCancellation()
        let preferences = LocalPreferencesStore.standard
        guard preferences[.accountDataGeneration] == accountDataGeneration,
              !isCleanupPending() else {
            throw UploadError.cancelled
        }
    }

    @MainActor
    private func registerCategory(_ category: Category) {
        categories.insert(category)
    }

    @concurrent
    private func currentAccountId() async -> String? {
        if let accountIdProvider {
            return await accountIdProvider()
        }
        return await MainActor.run {
            guard let account = self.account, account.signedIn else {
                return nil
            }
            return account.details?.accountId
        }
    }

    func resumePendingUploads() async {
        let replayTask = startPendingUploadReplay()
        await replayTask.value
    }

    @discardableResult
    private func startPendingUploadReplay() -> Task<Void, Never> {
        replayGeneration &+= 1
        let previousReplayTask = orphanReplayTask
        previousReplayTask?.cancel()
        let generation = replayGeneration
        let replayTask = Task(priority: .utility) { @concurrent [weak self] in
            await previousReplayTask?.value
            guard !Task.isCancelled else {
                return
            }
            await self?.resumePendingUploads(generation: generation)
        }
        orphanReplayTask = replayTask
        return replayTask
    }

    private func resumeQueueIfReplayIsCurrent(_ generation: UInt) async -> Bool {
        guard replayGeneration == generation else {
            return false
        }
        await uploadQueue.resume()
        return replayGeneration == generation
    }
}


extension ManagedFileUpload {
    @concurrent
    private func resumePendingUploads(generation: UInt) async {
        guard !isCleanupPending() else {
            return
        }
        guard let accountId = await currentAccountId(), !accountId.isEmpty else {
            return
        }
        let categories = await categories
        do {
            try Task.checkCancellation()
            guard await resumeQueueIfReplayIsCurrent(generation) else {
                return
            }
            for category in categories {
                try Task.checkCancellation()
                let stagingDirectory = stagingDirectory(for: category)
                try createDirectoryIfNeeded(at: stagingDirectory)
                for fileUrl in try stagedFiles(in: stagingDirectory) {
                    try Task.checkCancellation()
                    guard let queueGeneration = await uploadQueue.reservation() else {
                        return
                    }
                    _ = await uploadQueue.enqueue(
                        .init(fileUrl: fileUrl, category: category, accountId: accountId),
                        generation: queueGeneration
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await logger.error("Unable to resume pending uploads: \(error)")
        }
    }

    nonisolated
    private func stagedFiles(in directory: URL) throws -> [URL] {
        guard fileManager.isDirectory(at: directory) else {
            return []
        }
        return try fileManager.contents(of: directory).filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    nonisolated
    private func createDirectoryIfNeeded(at url: URL) throws {
        if !fileManager.isDirectory(at: url) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directoryUrl = url
        try? directoryUrl.setResourceValues(resourceValues)
    }

    nonisolated private func stagingDirectory(for category: Category) -> URL {
        directory.appending(component: category.id, directoryHint: .isDirectory)
    }

    nonisolated
    private func moveToStaging(_ sourceUrl: URL, in directory: URL) throws -> URL {
        try stagingLock.withLock { _ in
            let preferredUrl = directory.appending(component: sourceUrl.lastPathComponent, directoryHint: .notDirectory)
            let stagingUrl = if fileManager.fileExists(atPath: preferredUrl.path(percentEncoded: false)) {
                directory.appending(
                    component: "\(UUID().uuidString)-\(sourceUrl.lastPathComponent)",
                    directoryHint: .notDirectory
                )
            } else {
                preferredUrl
            }
            try fileManager.moveItem(at: sourceUrl, to: stagingUrl)
            return stagingUrl
        }
    }
}


extension ManagedFileUpload {
    @MainActor
    private func incrementTotalNumUploads(for category: Category) {
        if let uploadProgress = progressByCategory[category] {
            uploadProgress.totalUnitCount += 1
        } else {
            let progress = Progress(totalUnitCount: 1)
            progress.localizedDescription = String(localized: category.title)
            progressByCategory[category] = progress
        }
    }

    @MainActor
    private func incrementNumCompletedUploads(for category: Category) {
        progressByCategory[category]?.completedUnitCount += 1
        if progressByCategory[category]?.isFinished == true {
            progressByCategory[category] = nil
        }
    }

    /// Uploads a file using the account identity captured when it entered durable staging.
    @concurrent
    private func uploadAndDelete(_ upload: PendingUpload) async {
        guard !Task.isCancelled else {
            return
        }
        await incrementTotalNumUploads(for: upload.category)

        do {
            if let uploadOperation {
                try await uploadOperation(upload.fileUrl, upload.category, upload.accountId)
            } else {
                let storageRef = Storage.storage().reference(
                    withPath: "users/\(upload.accountId)/\(upload.category.firebasePath)/\(upload.fileUrl.lastPathComponent)"
                )
                let bucket = storageRef.bucket
                let path = storageRef.fullPath
                await logger.notice("uploading to \(bucket):\(path)")
                let metadata = StorageMetadata()
                metadata.contentType = "application/octet-stream"
                try await storageRef.putFileRespectingCancellation(from: upload.fileUrl, metadata: metadata)
            }
            try Task.checkCancellation()
            try fileManager.removeItem(at: upload.fileUrl)
        } catch {
            if !Task.isCancelled {
                await logger.error("Upload of \(upload.fileUrl.lastPathComponent) failed: \(error)")
            }
        }
        await incrementNumCompletedUploads(for: upload.category)
    }
}
