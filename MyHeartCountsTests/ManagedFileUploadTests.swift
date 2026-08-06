//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import SpeziFoundation
import Testing


private actor UploadProbe {
    private(set) var activeCount = 0
    private(set) var cancelledCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var startedCount = 0
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private var startedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init() {
        let (releaseStream, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        self.releaseStream = releaseStream
        self.releaseContinuation = releaseContinuation
    }

    func upload() async throws {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedCount += 1
        resumeStartedWaiters()
        do {
            for await _ in releaseStream {}
            try Task.checkCancellation()
        } catch {
            activeCount -= 1
            cancelledCount += 1
            throw error
        }
        activeCount -= 1
    }

    func releaseUploads() {
        releaseContinuation.finish()
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
        let completedCounts = startedWaiters.keys.filter { $0 <= startedCount }
        for count in completedCounts {
            let waiters = startedWaiters.removeValue(forKey: count) ?? []
            for waiter in waiters {
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

    @Test
    func limitsConcurrentUploadsAndPreservesCollidingFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let probe = UploadProbe()
        let uploader = ManagedFileUpload(
            categories: [category],
            directory: directory,
            accountIdProvider: { "account-a" },
            uploadOperation: { _, _, _ in
                try await probe.upload()
            }
        )

        let sources = try (0..<5).map { try makeSourceFile(index: $0, in: directory) }
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
        let stagedFiles = regularFiles(in: directory).filter { $0.deletingLastPathComponent().lastPathComponent == category.id }
        #expect(stagedFiles.count == 5)
        #expect(Set(stagedFiles.map(\.lastPathComponent)).count == 5)
        await probe.releaseUploads()
        await uploader.waitUntilQuiescent()

        #expect(await probe.startedCount == 5)
        #expect(await probe.maximumActiveCount == 2)
        #expect(recursiveFileCount(in: directory) == 0)
    }

    @Test
    func cancellationLeavesFilesForBoundedReplay() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let firstProbe = UploadProbe()
        let firstUploader = makeUploader(directory: directory, accountId: "account-a", probe: firstProbe)
        for index in 0..<4 {
            try await firstUploader.stage(
                try makeSourceFile(index: index, in: directory),
                category: category
            )
        }
        await firstProbe.waitUntilStarted(2)

        await firstUploader.cancelAndWaitForQuiescence()
        #expect(await firstProbe.cancelledCount == 2)
        #expect(await firstProbe.startedCount == 2)
        #expect(recursiveFileCount(in: directory) == 4)

        let replayProbe = UploadProbe()
        let replayUploader = makeUploader(directory: directory, accountId: "account-a", probe: replayProbe)
        await replayUploader.resumePendingUploads()
        await replayProbe.waitUntilStarted(2)
        #expect(await replayProbe.maximumActiveCount == 2)
        await replayProbe.releaseUploads()
        await replayUploader.waitUntilQuiescent()

        #expect(await replayProbe.startedCount == 4)
        #expect(await replayProbe.maximumActiveCount == 2)
        #expect(recursiveFileCount(in: directory) == 0)
    }

    @Test
    func cleanupGateBlocksPendingFilesFromTheNextAccount() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let categoryDirectory = directory.appending(component: category.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: categoryDirectory, withIntermediateDirectories: true)
        try Data("pending".utf8).write(to: categoryDirectory.appending(path: "pending.dat"))
        #expect(recursiveFileCount(in: directory) == 1)

        let probe = UploadProbe()
        let accountBUploader = makeUploader(
            directory: directory,
            accountId: "account-b",
            probe: probe,
            isCleanupPending: { true }
        )
        await accountBUploader.resumePendingUploads()

        #expect(await probe.startedCount == 0)
        #expect(recursiveFileCount(in: directory) == 1)
        try await accountBUploader.clearPendingUploads()
        #expect(recursiveFileCount(in: directory) == 0)
    }

    private func makeUploader(
        directory: URL,
        accountId: String,
        probe: UploadProbe,
        isCleanupPending: @escaping @Sendable () -> Bool = { false }
    ) -> ManagedFileUpload {
        ManagedFileUpload(
            categories: [category],
            directory: directory,
            accountIdProvider: { accountId },
            uploadOperation: { _, _, _ in
                try await probe.upload()
            },
            isCleanupPending: isCleanupPending
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(
            path: "managed-file-upload-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSourceFile(index: Int, in testDirectory: URL) throws -> URL {
        let directory = testDirectory
            .appending(path: "sources", directoryHint: .isDirectory)
            .appending(path: "\(index)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "upload.dat", directoryHint: .notDirectory)
        try Data("test-\(index)".utf8).write(to: url)
        return url
    }

    private func recursiveFileCount(in directory: URL) -> Int {
        regularFiles(in: directory).count
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
