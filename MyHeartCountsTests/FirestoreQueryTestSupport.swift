//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseCore
import FirebaseFirestore
import Foundation
@testable import MyHeartCounts
import Synchronization
import Testing


@MainActor
func withQueryTestFirestore(_ operation: (Firestore) async throws -> Void) async throws {
    let name = "firestore-metadata-\(UUID().uuidString)"
    let options = FirebaseOptions(googleAppID: "1:1234567890:ios:abcdef", gcmSenderID: "1234567890")
    options.projectID = "demo-firestore-metadata"
    options.apiKey = "A" + String(repeating: "0", count: 38)
    FirebaseApp.configure(name: name, options: options)
    let app = try #require(FirebaseApp.app(name: name))
    let firestore = Firestore.firestore(app: app)
    let settings = FirestoreSettings()
    settings.cacheSettings = MemoryCacheSettings()
    settings.host = "127.0.0.1:9"
    settings.isSSLEnabled = false
    firestore.settings = settings
    do {
        try await firestore.disableNetwork()
        try await operation(firestore)
        try await firestore.terminate()
    } catch {
        try? await firestore.terminate()
        _ = await app.delete()
        throw error
    }
    #expect(await app.delete())
}


/// Allows metadata transitions without requiring a live Firestore server.
@MainActor
final class FirestoreQueryTestSource {
    private final class Registration: NSObject, ListenerRegistration {
        func remove() {}
    }

    private var receivers: [@MainActor @Sendable (Result<MHCFirestoreQueryInput, any Error>) -> Void] = []

    func subscribe(
        _ query: Query,
        receive: @escaping @MainActor @Sendable (Result<MHCFirestoreQueryInput, any Error>) -> Void
    ) -> any ListenerRegistration {
        receivers.append(receive)
        return Registration()
    }

    func send(_ input: MHCFirestoreQueryInput, to index: Int? = nil) {
        receivers[index ?? (receivers.count - 1)](.success(input))
    }
}


/// Runs a synchronous main-actor action during a decoder/processor call.
/// Release runs directly on the main queue, so it does not need another cooperative-pool worker.
final class FirestoreProcessingProbe: Sendable, Hashable {
    private struct State {
        var count = 0
        var action: (@MainActor @Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.count } }

    static func == (lhs: FirestoreProcessingProbe, rhs: FirestoreProcessingProbe) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func record() throws {
        let action = state.withLock { state in
            state.count += 1
            defer { state.action = nil }
            return state.action
        }
        guard let action else {
            return
        }
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.main.async {
            action()
            completion.leave()
        }
        // Fail instead of hanging if an action accidentally waits for the blocked processor.
        try #require(completion.wait(timeout: .now() + 5) == .success, "Processing probe action did not finish")
    }

    func duringNextCall(_ action: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { $0.action = action }
    }
}
