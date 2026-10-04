//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import HealthKit
@testable import MyHeartCounts
import Testing


/// M15: the ledger is bound to this device through a token the keychain keeps out of backups and other devices.
@Suite
struct FHIRExchangeLedgerDeviceBindingTests {
    @Test
    func matchingTokenKeepsTheLedger() throws {
        try withTemporaryDirectory { root in
            let binding = InMemoryDeviceBinding()
            let harness = LedgerHarness(ledger: .inDirectory(root, binding: binding))
            let sample = LedgerHarness.steps(0)
            let first = try harness.deliver([sample])
            try harness.ledger.closeForTesting()

            let reopened = LedgerHarness(identity: harness.identity, ledger: .inDirectory(root, binding: binding))
            #expect(try reopened.deliver([sample]).events == first.events)
        }
    }

    /// A ledger copied or restored onto a device whose keychain never held its token.
    @Test
    func missingTokenDiscardsTheLedger() throws {
        try discardsTheLedger(whenReopenedWith: InMemoryDeviceBinding())
    }

    /// A ledger copied from another installation, whose token differs from this device's.
    @Test
    func differingTokenDiscardsTheLedger() throws {
        try discardsTheLedger(whenReopenedWith: InMemoryDeviceBinding(token: FHIRExchangeLedger.newDeviceToken()))
    }

    @Test
    func emptyLedgerAdoptsTheDevicesToken() throws {
        try withTemporaryDirectory { root in
            let token = FHIRExchangeLedger.newDeviceToken()
            let binding = InMemoryDeviceBinding(token: token)
            let stored = try FHIRExchangeLedger.inDirectory(root, binding: binding).storedDeviceToken()

            #expect(stored == token)
            #expect(binding.storedToken == token)
        }
    }

    private func discardsTheLedger(whenReopenedWith otherBinding: InMemoryDeviceBinding) throws {
        try withTemporaryDirectory { root in
            let harness = LedgerHarness(ledger: .inDirectory(root))
            let sample = LedgerHarness.steps(0)
            let first = try #require(try harness.deliver([sample]).events[sample.uuid])
            try harness.ledger.closeForTesting()

            let reopened = LedgerHarness(identity: harness.identity, ledger: .inDirectory(root, binding: otherBinding))
            #expect(try reopened.ledger.entriesForTesting().isEmpty)
            #expect(try reopened.ledger.storedDeviceToken() == otherBinding.storedToken)
            let next = try #require(try reopened.deliver([sample]).events[sample.uuid])
            #expect(next.producerInstance != first.producerInstance)
            #expect(next.sequence.rawValue == "1")
        }
    }
}
