//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
@testable import GroveSensorKit
@testable import MyHeartCounts
import SensorKit
import Testing


/// What a reinstall leaves of SensorKit's identities.
///
/// The anchors and the retry state live in Application Support and go with the app, while the identity secret lives in
/// the synchronizable keychain and survives. A fresh anchor restarts at the coordinates of the one before it, under the
/// same key, store and account, so only its stream partition keeps the new installation's records apart from the earlier
/// installation's.
@Suite
struct SensorKitReinstallTests {
    private static let reports = (0..<3).map { DeviceUsageFHIRExchangeTests.report(textInputSessionIdentifier: "earlier-session-\($0)") }
    private static let reinstalledReports = (0..<3).map {
        DeviceUsageFHIRExchangeTests.report(textInputSessionIdentifier: "reinstalled-session-\($0)")
    }

    private let earlier: SensorKitPublicationHarness
    /// The installation after a reinstall: `earlier`'s identity secret, and a fresh store.
    private let reinstalled: SensorKitPublicationHarness
    private let earlierUploads = RecordedSensorKitUploads()
    private let reinstalledUploads = RecordedSensorKitUploads()

    init() {
        earlier = SensorKitPublicationHarness(sensor: Sensor.deviceUsage, sequence: 41)
        reinstalled = SensorKitPublicationHarness(
            sensor: Sensor.deviceUsage,
            sequence: earlier.sequence,
            store: FHIRExchangeStateStore(accountDataGeneration: earlier.store.accountDataGeneration, secretsSharedWith: earlier.store)
        )
    }

    /// The stream partition a fresh anchor mints with the first batch it persists.
    private static func freshStreamPartition() -> UInt64 {
        QueryAnchor().preparing(.sampleCount(deliveryTimestamp: SensorKitPublicationHarness.start, sampleCount: reports.count)).streamPartition
    }

    /// Publishes a batch of each installation, under `earlierPartition` and `reinstalledPartition`.
    private func publishBothInstallations(earlierPartition: UInt64, reinstalledPartition: UInt64) async throws {
        try await DeviceUsageFHIRExchangeTests.upload(
            Self.reports,
            publication: earlier.publication(uploads: earlierUploads, streamPartition: earlierPartition)
        )
        try await DeviceUsageFHIRExchangeTests.upload(
            Self.reinstalledReports,
            publication: reinstalled.publication(uploads: reinstalledUploads, streamPartition: reinstalledPartition)
        )
    }

    /// A fresh anchor after a reinstall yields source records disjoint from the earlier installation's, in the same
    /// repository, and so do the SensorKit source-record identifiers they disclose.
    @Test
    func freshAnchorAfterAReinstallYieldsDisjointSourceRecords() async throws {
        #expect(
            try reinstalled.store.repositoryScope(.sensorKit, subject: reinstalled.subject)
                == earlier.store.repositoryScope(.sensorKit, subject: earlier.subject)
        )
        try await publishBothInstallations(earlierPartition: Self.freshStreamPartition(), reinstalledPartition: Self.freshStreamPartition())

        let earlierRecords = try earlierUploads.records
        let reinstalledRecords = try reinstalledUploads.records
        #expect(earlierRecords.count == Self.reports.count)
        #expect(reinstalledRecords.count == Self.reinstalledReports.count)
        #expect(Set(earlierRecords.map(\.sourceRecord)).isDisjoint(with: reinstalledRecords.map(\.sourceRecord)))

        let earlierNativeIDs = try DeviceUsageFHIRExchangeTests.nativeRecordIDs(in: try #require(try earlierUploads.bundles.first))
        let reinstalledNativeIDs = try DeviceUsageFHIRExchangeTests.nativeRecordIDs(in: try #require(try reinstalledUploads.bundles.first))
        #expect(earlierNativeIDs.count == Self.reports.count)
        #expect(reinstalledNativeIDs.count == Self.reinstalledReports.count)
        #expect(earlierNativeIDs.isDisjoint(with: reinstalledNativeIDs))
    }

    /// What the partition prevents: coordinates repeated under one partition restate the earlier installation's source
    /// records with other content, as later versions that would silently replace them.
    @Test
    func coordinatesRepeatedUnderOnePartitionRestateTheEarlierSourceRecords() async throws {
        try await publishBothInstallations(earlierPartition: 0, reinstalledPartition: 0)

        let earlierRecords = try earlierUploads.records
        let reinstalledRecords = try reinstalledUploads.records
        #expect(earlierRecords.count == Self.reports.count)
        #expect(reinstalledRecords.map(\.sourceRecord) == earlierRecords.map(\.sourceRecord))
        #expect(Set(earlierRecords.map(\.version)).isDisjoint(with: reinstalledRecords.map(\.version)))
    }
}
