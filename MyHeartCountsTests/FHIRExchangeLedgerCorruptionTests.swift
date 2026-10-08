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


/// G14 on the GRDB ledger: Grove refuses a corrupt entry with a typed error instead of trapping or misreading
/// it, and MHC then empties the ledger, so the redelivery starts over on a fresh producer instance.
@Suite
struct FHIRExchangeLedgerCorruptionTests {
    enum Corruption: String, CaseIterable, Sendable {
        case eventIsNotJSON
        case zeroSequence
        case sequenceAtTheCounter
        case missingFacts
        case laterEntryVersion
        case blankApplicationName
        case invalidInstance
        case producerIsNotJSON

        /// Corrupts the ledger of one reserved sample and returns the error Grove must raise for it.
        func apply(to ledger: FHIRExchangeLedger) throws -> ExchangeProducer.LedgerError {
            let event = try #require(try ledger.entryKeys(prefixedBy: "event/").first)
            let facts = try #require(try ledger.entryKeys(prefixedBy: "facts/").first)
            var eventJSON = try ledger.jsonEntry(event)
            switch self {
            case .eventIsNotJSON:
                try ledger.setRawEntry(Data("not json".utf8), for: event)
                return .corruptEntry(key: event)
            case .zeroSequence:
                eventJSON["sequence"] = "0"
            case .sequenceAtTheCounter:
                eventJSON["sequence"] = try ledger.producerEntry().next
            case .missingFacts:
                try ledger.removeRawEntry(facts)
                return .corruptEntry(key: event)
            case .laterEntryVersion:
                eventJSON["v"] = 2
                try ledger.setJSONEntry(eventJSON, for: event)
                return .unsupportedEntryVersion(key: event, version: 2)
            case .blankApplicationName:
                var factsJSON = try ledger.jsonEntry(facts)
                var application = try #require(factsJSON["application"] as? [String: Any])
                application["name"] = ""
                factsJSON["application"] = application
                try ledger.setJSONEntry(factsJSON, for: facts)
                return .corruptEntry(key: facts)
            case .invalidInstance:
                eventJSON["instance"] = "not-a-uuid"
            case .producerIsNotJSON:
                try ledger.setRawEntry(Data("{".utf8), for: "producer")
                return .corruptEntry(key: "producer")
            }
            try ledger.setJSONEntry(eventJSON, for: event)
            return .corruptEntry(key: event)
        }
    }

    @Test(arguments: Corruption.allCases)
    func corruptEntryIsRefusedAndTheLedgerStartsOver(_ corruption: Corruption) async throws {
        let harness = LedgerHarness(ledger: .forTesting())
        let sample = LedgerHarness.steps(0)
        let first = try await #require(try harness.deliver([sample]).events[sample.uuid])
        let expected = try corruption.apply(to: harness.ledger)

        await #expect(throws: expected) {
            try await harness.deliver([sample])
        }
        #expect(try harness.ledger.entriesForTesting().isEmpty)

        let next = try await #require(try harness.deliver([sample]).events[sample.uuid])
        #expect(next.producerInstance != first.producerInstance)
        #expect(next.sequence.rawValue == "1")
    }

    /// A writer whose generation rotated cannot empty the ledger on a corrupt entry: the recovery is fenced too.
    @Test
    func recoveryIsFencedToTheWritersGeneration() async throws {
        let preferences = TestAccountPreferences(generation: 1)
        let ledger = FHIRExchangeLedger(location: .inMemory, fence: preferences.fence)
        let harness = LedgerHarness(ledger: ledger)
        let sample = LedgerHarness.steps(0)
        _ = try await harness.deliver([sample], generation: 1)
        let entries = try ledger.entriesForTesting()

        #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try ledger.recover(accountDataGeneration: 0)
        }
        #expect(try ledger.entriesForTesting() == entries)
    }
}
