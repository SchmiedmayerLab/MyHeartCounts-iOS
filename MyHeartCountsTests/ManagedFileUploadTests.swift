//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveFoundation
import GroveTesting
@testable import MyHeartCounts
import Synchronization
import Testing


/// Stands in for the Firebase Storage upload, and records what the module asked it to do.
///
/// Uploads block until ``releaseUploads()`` is called, so that a test can observe how many run concurrently.
private actor UploadProbe {
    private(set) var activeCount = 0
    private(set) var cancelledCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var startedCount = 0
    /// The remote names the module asked for, in the order the uploads started.
    private(set) var requestedFilenames: [String] = []
    private(set) var requestedCategoryIds: [String] = []
    /// The account directories the module wanted to upload into.
    private(set) var requestedAccountIds: Set<String> = []

    private var isReleased = false
    private var startedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func upload(categoryId: String, filename: String, accountId: String) async throws {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedCount += 1
        requestedFilenames.append(filename)
        requestedCategoryIds.append(categoryId)
        requestedAccountIds.insert(accountId)
        resumeStartedWaiters()
        do {
            // Polling rather than a continuation: several uploads wait here at once, and `Task.sleep` already does
            // exactly the right thing on cancellation.
            while !isReleased {
                try await Swift::Task.sleep(for: .milliseconds(5))
            }
        } catch {
            activeCount -= 1
            cancelledCount += 1
            throw error
        }
        activeCount -= 1
    }

    func releaseUploads() {
        isReleased = true
    }

    func waitUntilStarted(_ count: Int) async {
        guard startedCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters[count, default: []].append(continuation)
        }
    }

    private func resumeStartedWaiters() {
        for count in startedWaiters.keys where count <= startedCount {
            for waiter in startedWaiters.removeValue(forKey: count) ?? [] {
                waiter.resume()
            }
        }
    }
}


@Suite(.serialized)
@MainActor
struct ManagedFileUploadTests {
    private let category = ManagedFileUpload.Category(
        id: "TestUploads",
        title: "Test Uploads",
        firebasePath: "test-uploads"
    )

    /// Concurrency is bounded, colliding source filenames all survive staging, and the remote name is always the
    /// caller's `lastPathComponent` — which callers that record a reference to a file before it is uploaded rely on.
    @Test
    func limitsConcurrentUploadsAndPreservesCollidingFilenames() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let probe = UploadProbe()
        let uploader = makeUploader(root: root, accountId: "account-a", probe: probe)
        resolveDependencies(of: uploader)

        // All five are named `upload.dat`; only the directory they sit in differs.
        let sources = try (0..<5).map { try makeSourceFile(index: $0, in: root) }
        let category = category
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    try await uploader.stage(source, category: category)
                }
            }
            try await group.waitForAll()
        }

        await probe.waitUntilStarted(2)
        #expect(await probe.maximumActiveCount == 2)
        // A flat, id-named staging directory makes collisions structurally impossible: five identically named
        // sources become five distinct staged files, with no renaming and no lock.
        let staged = regularFiles(in: uploader.stagingDirectory)
        #expect(staged.count == 5)
        #expect(Set(staged.map(\.lastPathComponent)).count == 5)

        await probe.releaseUploads()
        await uploader.waitUntilQuiescent()

        #expect(await probe.startedCount == 5)
        #expect(await probe.maximumActiveCount == 2)
        #expect(await probe.requestedFilenames == Array(repeating: "upload.dat", count: 5))
        #expect(regularFiles(in: uploader.stagingDirectory).isEmpty)
    }

    /// Cancelling leaves the staged files and their entries in place, and a later instance picks all of them back up.
    @Test
    func cancellationLeavesEntriesForReplay() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let firstProbe = UploadProbe()
        let firstUploader = makeUploader(root: root, accountId: "account-a", probe: firstProbe)
        resolveDependencies(of: firstUploader)
        for index in 0..<4 {
            try await firstUploader.stage(try makeSourceFile(index: index, in: root), category: category)
        }
        await firstProbe.waitUntilStarted(2)

        await firstUploader.cancelAndWaitForQuiescence()
        #expect(await firstProbe.cancelledCount == 2)
        #expect(await firstProbe.startedCount == 2)
        #expect(regularFiles(in: firstUploader.stagingDirectory).count == 4)

        let replayProbe = UploadProbe()
        let replayUploader = makeUploader(root: root, accountId: "account-a", probe: replayProbe)
        resolveDependencies(of: replayUploader)
        await replayUploader.resumePendingUploads()
        await replayProbe.waitUntilStarted(2)
        #expect(await replayProbe.maximumActiveCount == 2)
        await replayProbe.releaseUploads()
        await replayUploader.waitUntilQuiescent()

        #expect(await replayProbe.startedCount == 4)
        #expect(regularFiles(in: replayUploader.stagingDirectory).isEmpty)
    }

    /// While cleanup from a previous account is pending, nothing is uploaded and nothing new is accepted —
    /// and clearing afterwards removes every trace, including legacy per-category directories.
    @Test
    func cleanupGateBlocksUploadsFromTheNextAccount() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let probe = UploadProbe()
        let uploader = makeUploader(root: root, accountId: "account-b", probe: probe, isCleanupPending: { true })
        resolveDependencies(of: uploader)
        // Seed a file the way the old, file-system-based module would have left it behind.
        let legacyDirectory = uploader.configuration.directory.appending(component: category.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("pending".utf8).write(to: legacyDirectory.appending(path: "pending.dat"))

        await uploader.resumePendingUploads()
        #expect(await probe.startedCount == 0)
        #expect(regularFiles(in: uploader.configuration.directory).count == 1)

        // Staging is refused outright rather than quarantined: mixing accounts is worse than dropping a batch.
        await #expect(throws: (any Error).self) {
            try await uploader.stage(try makeSourceFile(index: 99, in: root), category: category)
        }

        try await uploader.clearPendingUploads()
        #expect(regularFiles(in: uploader.configuration.directory).isEmpty)
    }

    /// An entry staged for one account is never uploaded into another account's directory.
    @Test
    func neverUploadsIntoADifferentAccountsDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        // Staged for account-a, but its upload always fails, so the entry survives on disk.
        var failingConfiguration = makeConfiguration(root: root, accountId: "account-a")
        failingConfiguration.uploadOperation = { _, _, _, _, _ in
            throw CocoaError(.fileNoSuchFile)
        }
        let firstUploader = ManagedFileUpload(categories: [category], configuration: failingConfiguration)
        resolveDependencies(of: firstUploader)
        try await firstUploader.stage(try makeSourceFile(index: 0, in: root), category: category)
        await firstUploader.waitUntilQuiescent()
        #expect(regularFiles(in: firstUploader.stagingDirectory).count == 1)

        let secondProbe = UploadProbe()
        let secondUploader = makeUploader(root: root, accountId: "account-b", probe: secondProbe)
        resolveDependencies(of: secondUploader)
        await secondUploader.resumePendingUploads()
        await secondUploader.waitUntilQuiescent()

        #expect(await secondProbe.startedCount == 0)
        #expect(await secondProbe.requestedAccountIds.isEmpty)
        // The entry and its file are dropped rather than retained: keeping them would mean holding the previous
        // participant's data on the device indefinitely.
        #expect(regularFiles(in: secondUploader.stagingDirectory).isEmpty)
    }

    /// A failed attempt is retried within the launch for as long as the configuration allows; after that the entry
    /// waits for the next resume, which picks it up again.
    @Test
    func retriesFailedUploadsWithinTheLaunch() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let attempts = Mutex(0)
        var configuration = makeConfiguration(root: root, accountId: "account-a")
        // Two in-launch attempts, then give up until the next resume.
        configuration.retryDelay = { failedAttempts in failedAttempts < 2 ? .milliseconds(10) : nil }
        configuration.uploadOperation = { _, _, _, _, _ in
            let attempt = attempts.withLock { attempts in
                attempts += 1
                return attempts
            }
            guard attempt >= 3 else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        let uploader = ManagedFileUpload(categories: [category], configuration: configuration)
        resolveDependencies(of: uploader)
        try await uploader.stage(try makeSourceFile(index: 0, in: root), category: category)
        // `waitUntilQuiescent()` deliberately doesn't cover the delay between attempts, so poll for the retry instead.
        let deadline = ContinuousClock.now + .seconds(5)
        while attempts.withLock({ $0 }) < 2, ContinuousClock.now < deadline {
            try await Swift::Task.sleep(for: .milliseconds(10))
        }
        try await Swift::Task.sleep(for: .milliseconds(100))
        #expect(attempts.withLock { $0 } == 2)
        #expect(regularFiles(in: uploader.stagingDirectory).count == 1)

        await uploader.resumePendingUploads()
        await uploader.waitUntilQuiescent()
        #expect(attempts.withLock { $0 } == 3)
        #expect(regularFiles(in: uploader.stagingDirectory).isEmpty)
    }

    /// Clearing reopens the queue, so staging keeps working afterwards.
    @Test
    func clearingLeavesTheQueueUsable() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let probe = UploadProbe()
        let uploader = makeUploader(root: root, accountId: "account-a", probe: probe)
        resolveDependencies(of: uploader)
        try await uploader.clearPendingUploads()
        try await uploader.stage(try makeSourceFile(index: 0, in: root), category: category)
        await probe.waitUntilStarted(1)
        #expect(await probe.startedCount == 1)
        await probe.releaseUploads()
        await uploader.waitUntilQuiescent()
        #expect(regularFiles(in: uploader.stagingDirectory).isEmpty)
    }


    /// Resolves the module's dependencies the way the app's configuration would, i.e. including the background-task
    /// and lifecycle plumbing it hooks into (whose `configure()`s are inert here: no launch handler can be registered
    /// this late, and there is no scene).
    private func resolveDependencies(of uploader: ManagedFileUpload) {
        withDependencyResolution {
            uploader
            MHCBackgroundTasks()
            Lifecycle()
            LocalNotifications()
        }
    }

    private func makeConfiguration(root: URL, accountId: String) -> ManagedFileUpload.Configuration {
        var configuration = ManagedFileUpload.Configuration()
        configuration.directory = root.appending(component: "uploads", directoryHint: .isDirectory)
        configuration.databaseDirectory = root.appending(component: "database", directoryHint: .isDirectory)
        configuration.accountIdProvider = { accountId }
        return configuration
    }

    private func makeUploader(
        root: URL,
        accountId: String,
        probe: UploadProbe,
        isCleanupPending: @escaping @Sendable () -> Bool = { false }
    ) -> ManagedFileUpload {
        var configuration = makeConfiguration(root: root, accountId: accountId)
        configuration.uploadOperation = { _, category, accountId, filename, _ in
            try await probe.upload(categoryId: category.id, filename: filename, accountId: accountId)
        }
        configuration.isCleanupPending = isCleanupPending
        return ManagedFileUpload(categories: [category], configuration: configuration)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(
            path: "managed-file-upload-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSourceFile(index: Int, in root: URL) throws -> URL {
        let directory = root
            .appending(path: "sources", directoryHint: .isDirectory)
            .appending(path: "\(index)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "upload.dat", directoryHint: .notDirectory)
        try Data("test-\(index)".utf8).write(to: url)
        return url
    }

    private func regularFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}


extension ManagedFileUploadTests {
    /// Clearing a category also resumes unrelated uploads that were active or still waiting in the queue,
    /// even when the cleared category has no pending uploads of its own.
    @Test(arguments: [false, true])
    func clearingOneCategoryResumesOtherUploads(hasUploadsInClearedCategory: Bool) async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let probe = UploadProbe()
        let uploader = makeUploader(root: root, accountId: "account-a", probe: probe)
        resolveDependencies(of: uploader)
        let clearedCategory = ManagedFileUpload.Category(id: "Historical", title: "Historical", firebasePath: "historical")
        if hasUploadsInClearedCategory {
            try await uploader.stage(try makeSourceFile(index: 99, in: root), category: clearedCategory)
            await probe.waitUntilStarted(1)
        }
        for index in 0..<3 {
            try await uploader.stage(try makeSourceFile(index: index, in: root), category: category)
        }
        await probe.waitUntilStarted(2)

        try await uploader.clearPendingUploads(for: clearedCategory)
        #expect(await probe.cancelledCount == 2)
        #expect(regularFiles(in: uploader.stagingDirectory).count == 3)
        await probe.releaseUploads()
        await uploader.waitUntilQuiescent()

        #expect(await probe.startedCount == 5)
        let clearedCategoryAttempts = await probe.requestedCategoryIds.filter { $0 == clearedCategory.id }
        #expect(clearedCategoryAttempts.count == (hasUploadsInClearedCategory ? 1 : 0))
        #expect(regularFiles(in: uploader.stagingDirectory).isEmpty)
    }

    /// A filesystem error is still reported, but does not strand uploads in other categories.
    @Test
    func failedCategoryClearResumesOtherUploads() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let probe = UploadProbe()
        let uploader = makeUploader(root: root, accountId: "account-a", probe: probe)
        resolveDependencies(of: uploader)
        try await uploader.stage(try makeSourceFile(index: 0, in: root), category: category)
        await probe.waitUntilStarted(1)

        let clearedCategory = ManagedFileUpload.Category(id: "Historical", title: "Historical", firebasePath: "historical")
        let legacyDirectory = uploader.configuration.directory.appending(component: clearedCategory.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("pending".utf8).write(to: legacyDirectory.appending(path: "pending.dat"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: legacyDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacyDirectory.path)
        }

        await #expect(throws: CocoaError.self) {
            try await uploader.clearPendingUploads(for: clearedCategory)
        }
        await probe.releaseUploads()
        await uploader.waitUntilQuiescent()
        #expect(await probe.cancelledCount == 1)
        #expect(await probe.startedCount == 2)
        #expect(regularFiles(in: uploader.stagingDirectory).isEmpty)
    }
}
