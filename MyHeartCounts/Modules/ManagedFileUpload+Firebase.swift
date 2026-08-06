//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseStorage
import Foundation
import Synchronization


private enum StorageUploadError: Error, Sendable {
    case failed(String)
}


private final class StorageUploadCancellation: Sendable {
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


extension StorageReference {
    func putFileRespectingCancellation(
        from url: URL,
        metadata: StorageMetadata
    ) async throws {
        let cancellation = StorageUploadCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = putFile(from: url, metadata: metadata) { metadata, error in
                    if let error {
                        continuation.resume(throwing: StorageUploadError.failed(String(describing: error)))
                    } else if metadata == nil {
                        continuation.resume(throwing: StorageUploadError.failed("Missing upload metadata"))
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
