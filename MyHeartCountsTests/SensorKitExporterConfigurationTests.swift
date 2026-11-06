//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKit
@testable import MyHeartCounts
import SensorKit
import Testing


/// A visit at a fixed location of interest.
private final class PinnedVisit: SRVisit, @unchecked Sendable {
    static let locationID = UUID(uuidString: "5B0E7F3A-9C1D-4E2F-8A6B-7C8D9E0F1A2B")! // swiftlint:disable:this force_unwrapping

    override var identifier: UUID {
        Self.locationID
    }
    override var distanceFromHome: Double {
        1_250
    }
    override var arrivalDateInterval: DateInterval {
        DateInterval(start: SensorKitPublicationHarness.start, duration: 600)
    }
    override var departureDateInterval: DateInterval {
        DateInterval(start: SensorKitPublicationHarness.start.addingTimeInterval(3_600), duration: 600)
    }
    override var locationCategory: SRVisit.LocationCategory {
        .work
    }
}


/// The configuration MHC's SensorKit exporter factory passes Grove, pinned through the graphs it exports, as no part of
/// it can change without re-identifying, or silently changing, every SensorKit record already exported.
@Suite
struct SensorKitExporterConfigurationTests {
    /// The source-record system of the known secret's key for the harness's participant.
    private static let sourceRecordSystem = "https://myheartcounts.stanford.edu/fhir/NamingSystem/grove-source-record-v0/s0XAQd11O/1"
    /// The native record system of the harness's participant's SensorKit repository in the known store.
    private static let nativeRecordSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/sensorkit-record/blbshuKdrD7Z-dli9vXTELEQUhwSUKHs4K-b1DfNbHo"

    private let uploads = RecordedSensorKitUploads()

    /// The exact identities a known secret mints for a known record: its source-record identity in the SensorKit
    /// repository of the known store, and its SensorKit source-record identifier disclosed under the repository's own system.
    @Test
    func sensorKitRecordIdentityIsPinned() async throws {
        let harness = SensorKitPublicationHarness(sensor: Sensor.deviceUsage, sequence: 21)
        try harness.store.useKnownIdentitySecret()
        let publication = try harness.publication(uploads: uploads)
        try await DeviceUsageFHIRExchangeTests.upload([DeviceUsageFHIRExchangeTests.report()], publication: publication)
        let json = try #require(try uploads.graphs.first)
        let identifiers = try statedIdentifiers(in: json)
        let sourceRecordID = "d9ce6dfa-7434-8c4f-b454-5d6f002f332e"
        let sourceRecord = "v0:s0XAQd11O:1:aOQs7GYB8LxoyBVNjpP0wBSWdVy_h4swt2MNvujoFU4"

        #expect(identifiers.contains { $0.system == Self.nativeRecordSystem && $0.value == sourceRecordID })
        #expect(Set(identifiers.filter { $0.system == Self.sourceRecordSystem }.map(\.value)) == [sourceRecord])
        // That is the record's source-record identity in the SensorKit repository of the known store.
        let repository = try BusinessIdentifier(
            system: FHIRExchangeIdentifiers.repository,
            value: "sensorkit:3f8a1d2e-4b5c-6d7e-8f90-a1b2c3d4e5f6:sensorkit-test-participant"
        )
        #expect(try harness.store.identityScope(subject: harness.subject).sourceRecord(
            adapterID: "sensorkit",
            sourceType: publication.sourceToken,
            repositoryScope: repository,
            nativeRecordID: sourceRecordID
        ).identifier.identifier.value == sourceRecord)
    }

    /// A visit states its location of interest under MHC's own visit-location system, and under no other.
    @Test
    func visitStatesItsLocationUnderTheVisitLocationSystem() async throws {
        let harness = SensorKitPublicationHarness(sensor: Sensor.visits, sequence: 22)
        let visits = try SRVisit.processIntoSafeRepresentation([(SensorKitPublicationHarness.start, PinnedVisit())])
        try await UploadStrategyStructured<SRVisit>().upload(
            visits,
            publication: harness.publication(uploads: uploads),
            for: Sensor.visits,
            activity: SensorKitDataFetcher.InProgressActivity(sensor: Sensor.visits)
        )
        let json = try #require(try uploads.graphs.first)
        let locationID = PinnedVisit.locationID.uuidString.lowercased()

        #expect(
            try statedIdentifiers(in: json).filter { $0.value == locationID }.map(\.system)
                == ["https://myheartcounts.stanford.edu/fhir/identifiers/sensorkit-visit-location"]
        )
    }
}
