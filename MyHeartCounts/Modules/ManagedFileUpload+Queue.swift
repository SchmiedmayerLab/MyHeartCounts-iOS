//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension ManagedFileUpload {
    struct PendingUpload: Sendable {
        let fileUrl: URL
        let category: Category
        let accountId: String
    }

    actor UploadQueue {
        typealias Operation = @Sendable (PendingUpload) async -> Void

        private let maximumConcurrentUploads: Int
        private let operation: Operation
        private var acceptsUploads = true
        private var generation: UInt = 0
        private var pending: [PendingUpload] = []
        private var pendingIndex = 0
        private var activeTasks: [URL: Task<Void, Never>] = [:]
        private var enqueuedUrls: Set<URL> = []
        private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

        private var hasPendingUploads: Bool {
            pendingIndex < pending.endIndex
        }

        init(maximumConcurrentUploads: Int, operation: @escaping Operation) {
            precondition(maximumConcurrentUploads > 0)
            self.maximumConcurrentUploads = maximumConcurrentUploads
            self.operation = operation
        }

        func reservation() -> UInt? {
            acceptsUploads ? generation : nil
        }

        func enqueue(_ upload: PendingUpload, generation: UInt) -> Bool {
            guard acceptsUploads, generation == self.generation else {
                return false
            }
            guard enqueuedUrls.insert(upload.fileUrl).inserted else {
                return true
            }
            pending.append(upload)
            startUploadsIfPossible()
            return true
        }

        func pauseAndCancel() async {
            acceptsUploads = false
            generation &+= 1

            let pending = Array(pending[pendingIndex...])
            self.pending.removeAll()
            pendingIndex = 0
            for upload in pending {
                enqueuedUrls.remove(upload.fileUrl)
            }

            let activeTasks = Array(activeTasks.values)
            activeTasks.forEach { $0.cancel() }
            for activeTask in activeTasks {
                await activeTask.value
            }
            resumeQuiescenceWaitersIfNeeded()
        }

        func resume() {
            acceptsUploads = true
            startUploadsIfPossible()
        }

        func waitUntilQuiescent() async {
            guard hasPendingUploads || !activeTasks.isEmpty else {
                return
            }
            await withCheckedContinuation { continuation in
                quiescenceWaiters.append(continuation)
            }
        }

        private func startUploadsIfPossible() {
            while acceptsUploads && activeTasks.count < maximumConcurrentUploads && hasPendingUploads {
                let upload = dequeuePendingUpload()
                let operation = operation
                let task = Task(priority: .utility) { @concurrent [weak self] in
                    if !Task.isCancelled {
                        await operation(upload)
                    }
                    await self?.uploadDidFinish(upload)
                }
                activeTasks[upload.fileUrl] = task
            }
        }

        private func uploadDidFinish(_ upload: PendingUpload) async {
            activeTasks[upload.fileUrl] = nil
            enqueuedUrls.remove(upload.fileUrl)
            startUploadsIfPossible()
            resumeQuiescenceWaitersIfNeeded()
        }

        private func resumeQuiescenceWaitersIfNeeded() {
            guard !hasPendingUploads && activeTasks.isEmpty else {
                return
            }
            let waiters = quiescenceWaiters
            quiescenceWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func dequeuePendingUpload() -> PendingUpload {
            let upload = pending[pendingIndex]
            pendingIndex += 1
            if pendingIndex == pending.endIndex {
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
            } else if pendingIndex >= 64, pendingIndex * 2 >= pending.count {
                pending.removeFirst(pendingIndex)
                pendingIndex = 0
            }
            return upload
        }
    }
}
