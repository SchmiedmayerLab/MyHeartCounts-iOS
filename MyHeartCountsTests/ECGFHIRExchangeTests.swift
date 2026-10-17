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
import GroveSensorKitFHIR
@testable import MyHeartCounts
import SensorKit
import Testing


/// Serialized: every test publishes the same session, whose batch file is staged under a name its identity derives.
@Suite(.serialized)
struct ECGFHIRExchangeTests {
    private struct Session {
        var startDate = SensorKitPublicationHarness.start
        var frequencyHertz: Double = 512
        var lead: SRElectrocardiogramSample.Lead = .rightArmMinusLeftArm
        var guidance: SRElectrocardiogramSession.SessionGuidance = .guided

        /// Eight samples at 512 Hz in two uniform batches, as SensorKit delivers them.
        var value: SensorKitECGSession {
            let samples = [12.5, -3.25, 40, 7.75].map { microvolts in
                SensorKitECGSession.Batch.VoltageSample(flags: [], voltage: Measurement(value: microvolts, unit: .microvolts))
            }
            return SensorKitECGSession(
                startDate: startDate,
                sessionIdentifier: "ecg-session",
                sessionStates: [.begin, .active, .end],
                frequency: Measurement(value: frequencyHertz, unit: .hertz),
                lead: lead,
                guidance: guidance,
                batches: [
                    .init(offset: 0, samples: samples),
                    .init(offset: 4 / 512.0, samples: samples)
                ]
            )
        }
    }

    private let harness = SensorKitPublicationHarness(sensor: Sensor.ecg, sequence: 31)
    private let uploads = RecordedSensorKitUploads()

    private static func upload(
        _ sessions: [SensorKitECGSession],
        publication: SensorKitBatchPublication
    ) async throws -> ExchangeProducer.Receipt? {
        try await UploadStrategyECG().upload(
            sessions,
            publication: publication,
            for: Sensor.ecg,
            activity: SensorKitDataFetcher.InProgressActivity(sensor: Sensor.ecg)
        )
    }

    /// A redelivery that changed any session property the graph states, at the same acquisition coordinate, fails its
    /// batch as drift before anything is exported or written, although Grove's own evidence of the session is unchanged.
    @Test
    func sessionPropertyDriftFailsTheBatch() async throws {
        let original = Session().value
        let failing = RecordedSensorKitUploads(failingStaging: true)
        await #expect(throws: RecordedSensorKitUploads.StageFailure.self) {
            _ = try await Self.upload([original], publication: harness.publication(uploads: failing))
        }
        let evidence = try SensorKitPreparedStructuredRecord(electrocardiogram: original).retryEvidence
        let sourceRecordID = try harness.publication(uploads: uploads).sourceRecordID(ordinal: 0, evidence: evidence)

        let drifts: [(property: String, drift: (inout Session) -> Void)] = [
            ("start", { $0.startDate.addTimeInterval(1) }),
            ("frequency", { $0.frequencyHertz = 256 }),
            ("lead", { $0.lead = .leftArmMinusRightArm }),
            ("guidance", { $0.guidance = .unguided })
        ]
        for (property, drift) in drifts {
            var drifted = Session()
            drift(&drifted)
            // Grove's evidence of the session omits the property, so only MHC's supplement can catch the drift.
            #expect(try SensorKitPreparedStructuredRecord(electrocardiogram: drifted.value).retryEvidence == evidence, "\(property)")
            let redelivered = RecordedSensorKitUploads()
            await #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceRecordID.value), "\(property)") {
                _ = try await Self.upload([drifted.value], publication: harness.publication(uploads: redelivered))
            }
            #expect(redelivered.all.isEmpty, "\(property)")
        }

        let receipt = try await Self.upload([original], publication: harness.publication(uploads: uploads))
        #expect(uploads.all == failing.all)
        receipt?.release()
        #expect(try harness.ledger.reservationCount == 0)
    }

    /// A batch pending from an earlier build, which recorded only Grove's evidence of the session, still matches its
    /// redelivery: the supplement is recorded beside that digest instead of replacing it.
    @Test
    func digestRecordedWithoutTheSupplementStillMatches() async throws {
        let session = Session().value
        let publication = try harness.publication(uploads: uploads)
        _ = try publication.sourceRecordID(
            ordinal: 0,
            evidence: try SensorKitPreparedStructuredRecord(electrocardiogram: session).retryEvidence
        )

        let receipt = try await Self.upload([session], publication: publication)
        #expect(try uploads.graphs.count == 1)
        receipt?.release()
    }
}
