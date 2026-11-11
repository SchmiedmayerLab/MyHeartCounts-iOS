//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
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

    /// The identity scope `secret` keys for `subject`.
    ///
    /// The key id is the per-subject fingerprint of the key: a re-minted key gets a new key id, so it never reuses the
    /// systems of the key it replaced, and the US and UK accounts of one participant, which share the key, state different
    /// key ids and stay unlinkable.
    static func identityScope(of secret: FHIRExchangeIdentitySecret, subject: FHIRExchangeSubject) throws -> OpaqueIdentityScope {
        let key = SymmetricKey(data: secret.key)
        return try OpaqueIdentityScope(
            root: FHIRExchangeIdentifiers.deploymentRoot,
            keyID: OpaqueIdentityScope.recommendedKeyID(
                prefix: FHIRExchangeIdentifiers.identityKeyIDPrefix,
                key: key,
                subject: subject.identity
            ),
            epoch: KeyEpoch(String(secret.epoch)),
            key: key
        )
    }

    /// The repository one source's records live in: the synced store `secret` belongs to, partitioned per account.
    ///
    /// The store id keeps the same reading's identities equal across the participant's devices
    /// and reinstalls; the account identity keeps different accounts unlinkable even though
    /// they share the store-bound key.
    static func repositoryScope(
        _ source: FHIRExchangeIdentifiers.SourceRepository,
        subject: FHIRExchangeSubject,
        secret: FHIRExchangeIdentitySecret
    ) throws -> BusinessIdentifier {
        try BusinessIdentifier(
            system: FHIRExchangeIdentifiers.repository,
            value: "\(source.rawValue):\(secret.storeID.uuidString.lowercased()):\(subject.identity.value)"
        )
    }

    /// The opaque segment that scopes the SensorKit record system to `repository`: HMAC-SHA-256 under the identity key,
    /// base64url without padding, over the length-framed label, the repository's system and its value.
    ///
    /// Keyed, as the repository's clear value holds the store id, which a participant's accounts share.
    static func sensorKitRecordScope(of repository: BusinessIdentifier, secret: FHIRExchangeIdentitySecret) -> String {
        var input = Data()
        for field in ["edu.stanford.myheartcounts.sensorkit-record-scope.v0", repository.system.rawValue, repository.value] {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret.key)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
