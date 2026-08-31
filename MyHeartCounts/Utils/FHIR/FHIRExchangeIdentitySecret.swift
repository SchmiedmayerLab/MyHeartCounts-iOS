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
/// It lives in the synchronizable keychain, so it survives reinstalls and, wherever iCloud Keychain
/// is on, reaches the participant's other devices. Account partitioning happens in the repository
/// scope, never by rotating this secret.
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
    private static func storedIdentitySecret(
        in keychain: KeychainStorage
    ) throws -> FHIRExchangeIdentitySecret? {
        guard let credentials = try keychain.retrieveCredentials(
            withUsername: "identity",
            for: identitySecretTag
        ) else {
            return nil
        }
        guard let data = Data(base64Encoded: credentials.password),
              let secret = try? JSONDecoder().decode(FHIRExchangeIdentitySecret.self, from: data) else {
            throw FHIRExchangeStateError.corruptIdentitySecret
        }
        return secret
    }

    func identityScope() throws -> PseudonymousIdentityScope {
        let secret = try identitySecret()
        let keyID = FHIRExchangeIdentifiers.identityKeyID
        let epoch = try CanonicalPositiveDecimal(secret.epoch)
        return try PseudonymousIdentityScope(
            systems: FHIRExchangeIdentifiers.pseudonymousSystems(keyID: keyID, epoch: epoch),
            keyID: keyID,
            epoch: epoch,
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
            if let stored = try Self.storedIdentitySecret(in: keychain) {
                return stored
            }
            let secret = FHIRExchangeIdentitySecret()
            let encoded = try JSONEncoder().encode(secret).base64EncodedString()
            do {
                try keychain.store(
                    Credentials(username: "identity", password: encoded),
                    for: Self.identitySecretTag,
                    replaceDuplicates: false
                )
                return secret
            } catch {
                // A concurrent first use won the mint. Replacing its secret would orphan every
                // identity it already put on the wire, so adopt the winner instead.
                guard let winner = try? Self.storedIdentitySecret(in: keychain) else {
                    throw error
                }
                return winner
            }
        }
    }
}
