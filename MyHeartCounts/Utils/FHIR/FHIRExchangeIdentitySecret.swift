//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveKeychainStorage
import Synchronization


/// The store-bound identity secret every device on the participant's Apple Account shares.
///
/// It lives in the synchronizable keychain, so it survives reinstalls and syncs across devices
/// exactly like the HealthKit store whose records it names: the same reading minted anywhere
/// yields the same identities. Account partitioning happens in the repository scope, never by
/// rotating this secret.
struct FHIRExchangeIdentitySecret: Codable, Sendable, Equatable {
    let key: Data
    let storeID: UUID
    let epoch: UInt64

    init() {
        var generator = SystemRandomNumberGenerator()
        self.key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        self.storeID = UUID()
        self.epoch = 1
    }
}


extension FHIRExchangeStateStore {
    func identityScope() throws -> PseudonymousIdentityScope {
        let secret = try identitySecret()
        return try PseudonymousIdentityScope(
            systems: FHIRExchangeIdentifiers.pseudonymousSystems,
            keyID: "store",
            epoch: CanonicalPositiveDecimal(secret.epoch),
            key: secret.key
        )
    }

    /// The repository one source's records live in: the synced store, partitioned per account.
    ///
    /// The store id keeps the same reading's identities equal across the participant's devices
    /// and reinstalls; the account identity keeps different accounts unlinkable even though
    /// they share the store-bound key.
    func repositoryScope(
        _ source: FHIRExchangeIdentifiers.SourceRepository,
        subject: FHIRExchangeSubject
    ) throws -> BusinessIdentifier {
        let secret = try identitySecret()
        return try BusinessIdentifier(
            system: FHIRExchangeIdentifiers.repository,
            value: "\(source.rawValue):\(secret.storeID.uuidString.lowercased()):\(subject.identity.value)"
        )
    }

    /// Loads the store-bound secret, minting and persisting one on first use.
    func identitySecret() throws -> FHIRExchangeIdentitySecret {
        switch secrets {
        case .memory(let backend):
            return backend.secret.withLock { stored in
                if let stored {
                    return stored
                }
                let secret = FHIRExchangeIdentitySecret()
                stored = secret
                return secret
            }
        case .keychain(let keychain):
            if let credentials = try keychain.retrieveCredentials(
                withUsername: "identity",
                for: Self.identitySecretTag
            ) {
                guard let data = Data(base64Encoded: credentials.password),
                      let secret = try? JSONDecoder().decode(FHIRExchangeIdentitySecret.self, from: data) else {
                    throw FHIRExchangeStateError.corruptIdentitySecret
                }
                return secret
            }
            let secret = FHIRExchangeIdentitySecret()
            let encoded = try JSONEncoder().encode(secret).base64EncodedString()
            try keychain.store(
                Credentials(username: "identity", password: encoded),
                for: Self.identitySecretTag
            )
            return secret
        }
    }
}
