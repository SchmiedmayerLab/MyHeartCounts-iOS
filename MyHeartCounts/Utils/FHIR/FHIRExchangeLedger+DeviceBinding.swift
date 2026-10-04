//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveKeychainStorage


/// Where the ledger's device token lives outside the database.
///
/// The database keeps a copy of the token. A database whose token differs from this store's, or a store
/// without a token while the database has one, means the database was restored or copied from elsewhere;
/// it is then emptied, as Grove's ledger may lose entries but never resurface old ones.
protocol FHIRExchangeLedgerDeviceBinding: Sendable {
    /// The token this device's ledger is bound to, created and stored on first use.
    func deviceToken() throws -> Data
}


/// The device token as a non-synchronizable, this-device-only keychain item, which neither iCloud Keychain
/// nor a restore onto another device brings along.
struct FHIRExchangeLedgerKeychainBinding: FHIRExchangeLedgerDeviceBinding {
    static let service = "edu.stanford.MyHeartCounts.fhirExchangeLedger"
    static let tag = CredentialsTag.genericPassword(
        forService: service,
        storage: .keychain(requireUserPresence: false, accessGroup: nil)
    )
    /// The account the token is stored under.
    static let username = "device"

    private let keychain = KeychainStorage()

    func deviceToken() throws -> Data {
        if let stored = try storedToken() {
            return stored
        }
        let token = FHIRExchangeLedger.newDeviceToken()
        do {
            try keychain.store(
                Credentials(username: Self.username, password: token.base64EncodedString()),
                for: Self.tag,
                replaceDuplicates: false
            )
            return token
        } catch {
            // A concurrent first use stored its token first; adopt it rather than replace it.
            guard let winner = try? storedToken() else {
                throw error
            }
            return winner
        }
    }

    /// The stored token; an unreadable item is deleted, so a new token replaces it.
    private func storedToken() throws -> Data? {
        guard let credentials = try keychain.retrieveCredentials(withUsername: Self.username, for: Self.tag) else {
            return nil
        }
        guard let token = Data(base64Encoded: credentials.password), !token.isEmpty else {
            try keychain.deleteCredentials(withUsername: Self.username, for: Self.tag)
            return nil
        }
        return token
    }
}


extension FHIRExchangeLedgerDeviceBinding where Self == FHIRExchangeLedgerKeychainBinding {
    static var keychain: Self {
        FHIRExchangeLedgerKeychainBinding()
    }
}
