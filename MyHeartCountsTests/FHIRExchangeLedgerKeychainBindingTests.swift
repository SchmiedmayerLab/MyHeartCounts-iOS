//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import Security
import Testing


/// M15 on the production binding: the device token is one keychain item that neither iCloud Keychain nor a backup
/// restored onto another device brings along, and every binding reads the same token from it.
///
/// The tests share that one item, so they run one at a time, and each removes the item only when it created it.
@Suite(.serialized)
final class FHIRExchangeLedgerKeychainBindingTests {
    /// The token item, whether synchronizable or not.
    private static var itemQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: FHIRExchangeLedgerKeychainBinding.service,
            kSecAttrAccount: FHIRExchangeLedgerKeychainBinding.username,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
    }

    /// Whether the item existed before the test.
    private let itemExisted: Bool

    init() throws {
        itemExisted = try !Self.storedItems().isEmpty
    }

    /// The attributes of every item the token could be stored in.
    private static func storedItems() throws -> [[String: Any]] {
        var query = itemQuery
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        try #require(status == errSecSuccess)
        return try #require(result as? [[String: Any]])
    }

    private static func ledger(in root: URL) -> FHIRExchangeLedger {
        FHIRExchangeLedger(
            location: .directory(root.appending(path: "FHIRExchangeLedger", directoryHint: .isDirectory)),
            deviceBinding: .keychain,
            fence: TestAccountPreferences().fence
        )
    }

    @Test
    func tokenIsStableAcrossBindings() throws {
        let token = try FHIRExchangeLedgerKeychainBinding().deviceToken()

        #expect(token.count == 32)
        #expect(try FHIRExchangeLedgerKeychainBinding().deviceToken() == token)
        #expect(try FHIRExchangeLedgerKeychainBinding().deviceToken() == token)
    }

    @Test
    func tokenIsOneThisDeviceOnlyItem() throws {
        _ = try FHIRExchangeLedgerKeychainBinding().deviceToken()
        let items = try Self.storedItems()

        try #require(items.count == 1)
        #expect(items[0][kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(items[0][kSecAttrSynchronizable as String] as? Bool == false)
    }

    /// A ledger bound through the keychain keeps its entries when it is opened again.
    @Test
    func ledgerReopenedOnThisDeviceKeepsItsEntries() async throws {
        try await withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: Self.ledger(in: root))
            let sample = LedgerHarness.steps(0)
            let first = try await harness.deliver([sample])
            try harness.ledger.closeForTesting()

            let reopened = LedgerHarness(identity: harness.identity, ledger: Self.ledger(in: root))
            await #expect(try reopened.deliver([sample]).events == first.events)
            #expect(try reopened.ledger.storedDeviceToken() == FHIRExchangeLedgerKeychainBinding().deviceToken())
        }
    }

    deinit {
        if !itemExisted {
            SecItemDelete(Self.itemQuery as CFDictionary)
        }
    }
}
