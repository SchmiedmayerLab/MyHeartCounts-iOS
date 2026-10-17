//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
import MyHeartCountsShared
import SensorKit
import Synchronization
import Testing

@testable import MyHeartCounts


/// Serialized: every test publishes the same records, whose batch files are staged under names their identities derive.
@Suite(.serialized)
struct DeviceUsageFHIRExchangeTests {
    private static let timestamp = Date(timeIntervalSince1970: 1_788_000_000.125)

    /// A report unlocked for longer than it lasted, which Grove refuses to convert.
    private static var refusedReport: SRDeviceUsageReport.SafeRepresentation {
        report(totalUnlockDuration: 900)
    }

    /// A report whose unlock duration is not a number, which Grove refuses to prepare.
    private static var unpreparableReport: SRDeviceUsageReport.SafeRepresentation {
        report(totalUnlockDuration: .nan)
    }

    private static var subject: FHIRExchangeSubject {
        get throws {
            try FHIRExchangeSubject(
                identity: BusinessIdentifier(
                    system: FHIRExchangeIdentifiers.participant,
                    value: "device-usage-test-participant"
                )
            )
        }
    }

    private let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
    private let store: FHIRExchangeStateStore
    private let ledger: FHIRExchangeLedger
    private let uploads = RecordedSensorKitUploads()

    init() {
        store = FHIRExchangeStateStore(accountDataGeneration: accountDataGeneration)
        ledger = .forTesting(accountDataGeneration: accountDataGeneration)
    }

    static func report(
        textInputSessionIdentifier: String = "text-session-1",
        totalUnlockDuration: TimeInterval = 123.75
    ) -> SRDeviceUsageReport.SafeRepresentation {
        let applicationCategory = SRDeviceUsageReport.CategoryKey(rawValue: "application-category")
        let notificationCategory = SRDeviceUsageReport.CategoryKey(rawValue: "notification-category")
        let webCategory = SRDeviceUsageReport.CategoryKey(rawValue: "web-category")
        return SRDeviceUsageReport.SafeRepresentation(
            timestamp: timestamp,
            duration: 600.25,
            totalScreenWakes: 9,
            totalUnlocks: 7,
            totalUnlockDuration: totalUnlockDuration,
            version: "algorithm-v0",
            appUsageByCategory: [
                applicationCategory: [
                    .init(
                        bundleIdentifier: "com.apple.Health",
                        relativeStartTime: 17.5,
                        usageTime: 42.25,
                        reportApplicationIdentifier: "report-app-1",
                        textInputSessions: [
                            .init(
                                duration: 3.5,
                                sessionType: .keyboard,
                                identifier: textInputSessionIdentifier
                            ),
                            .init(
                                duration: 5.25,
                                sessionType: .dictation,
                                identifier: "text-session-2"
                            )
                        ],
                        supplementalCategories: [
                            .init(identifier: "supplemental-2"),
                            .init(identifier: "supplemental-1")
                        ]
                    )
                ]
            ],
            notificationUsageByCategory: [
                notificationCategory: [
                    .init(
                        bundleIdentifier: "com.apple.MobileSMS",
                        event: .received
                    )
                ]
            ],
            webUsageByCategory: [
                webCategory: [.init(totalUsageTime: 84.5)]
            ]
        )
    }

    static func upload(
        _ reports: [SRDeviceUsageReport.SafeRepresentation],
        publication: SensorKitBatchPublication
    ) async throws -> ExchangeProducer.Receipt? {
        try await UploadStrategyStructured<SRDeviceUsageReport>().upload(
            reports,
            publication: publication,
            for: Sensor.deviceUsage,
            activity: SensorKitDataFetcher.InProgressActivity(sensor: Sensor.deviceUsage)
        )
    }

    /// The remote path of the batch archive that publishes the records `sourceRecordIDs` name.
    static func batchFilePath(of sourceRecordIDs: [SensorKitSourceRecordID]) -> String {
        ManagedFileUpload.Category(Sensor.deviceUsage).remotePath(for: HealthUploadBatch.filename(
            typePrefix: Sensor.deviceUsage.id,
            identifiers: sourceRecordIDs.map(\.uuid),
            fileExtension: "zip"
        ))
    }

    /// The publication production builds, so its account fence, ordinal-derived source ids, retry state and exporter
    /// are the ones under test rather than a copy of them.
    private func publication(
        accountDataGeneration: Int? = nil,
        uploads: RecordedSensorKitUploads? = nil,
        at conversionInstant: Date = DeviceUsageFHIRExchangeTests.timestamp
    ) throws -> SensorKitBatchPublication {
        let subject = try Self.subject
        return try SensorKitBatchPublication(
            sensor: Sensor.deviceUsage,
            batchInfo: SensorKit.BatchInfo(
                timeRange: Self.timestamp..<Self.timestamp.addingTimeInterval(600),
                device: SensorKit.DeviceInfo(SRDevice.current),
                acquisitionBatch: SensorKit.AcquisitionBatchCoordinate(
                    cursorTimestamp: Self.timestamp,
                    resetGeneration: 2,
                    sequence: 7
                )
            ),
            subject: subject,
            destination: FHIRExchangeDestination(
                accountDataGeneration: accountDataGeneration ?? self.accountDataGeneration,
                accountID: subject.identity.value
            ),
            stateStore: store,
            ledger: ledger,
            uploader: (uploads ?? self.uploads).uploader,
            conversionInstant: conversionInstant
        )
    }

    @Test
    func nestedDeviceUsageDriftCannotReuseReservedIdentity() throws {
        let publication = try publication()
        let sourceRecordID = try publication.sourceRecordID(
            ordinal: 0,
            evidence: try SensorKitPreparedStructuredRecord(deviceUsage: Self.report()).retryEvidence
        )

        #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceRecordID.value)) {
            _ = try publication.sourceRecordID(
                ordinal: 0,
                evidence: try SensorKitPreparedStructuredRecord(
                    deviceUsage: Self.report(textInputSessionIdentifier: "changed-session")
                ).retryEvidence
            )
        }
    }

    /// A refused record reserves nothing and stages nothing, and the batch it belongs to still completes.
    @Test
    func refusedRecordsDoNotFailTheirBatch() async throws {
        let receipt = try await Self.upload([Self.refusedReport, Self.refusedReport], publication: publication())

        #expect(uploads.all.isEmpty)
        #expect(try ledger.reservationCount == 0)
        receipt?.release()
    }

    @Test
    func accountFenceAbortsBatchInsteadOfRefusingRecord() async throws {
        let publication = try publication(accountDataGeneration: accountDataGeneration + 1)

        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            _ = try await Self.upload([Self.refusedReport], publication: publication)
        }
    }

    @Test
    func deviceUsageBundleCarriesMandatoryNativeRecordingDocument() async throws {
        let publication = try publication()
        let report = Self.report()
        let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
        let payload = try #require(prepared.nativePayload)
        let sourceID = try publication.sourceRecordID(ordinal: 0, evidence: prepared.retryEvidence)
        let recordingPath = "recordings/\(sourceID.value).json"

        let receipt = try await Self.upload([report], publication: publication)
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: try #require(try uploads.graphs.first))
        let documents = bundle.entry?.compactMap { $0.resource?.get(if: DocumentReference.self) } ?? []
        let document = try #require(documents.first)
        let content = try #require(document.content.first)

        #expect(documents.count == 1)
        #expect(document.content.count == 1)
        #expect(content.attachment.data == nil)
        #expect(content.attachment.url?.value?.url.absoluteString == recordingPath)
        #expect(try uploads.recordings[recordingPath] == payload)
        #expect(content.attachment.size?.value?.integer == Int32(payload.count))
        #expect(content.attachment.hash != nil)
        #expect(
            content.format?.code?.value?.string == RegisteredRecordingFormat.nativeRecording.rawValue
        )
        receipt?.release()
    }
}


// MARK: Publication

extension DeviceUsageFHIRExchangeTests {
    /// The batch is staged as one archive, named by the identities of its records, holding each record's graph and
    /// recording, and the batch's info; the batch's events stay reserved until its receipt is released.
    @Test
    func publishedBatchStagesOneArchiveOfItsGraphsAndRecordings() async throws {
        let publication = try publication()
        let report = Self.report()
        let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
        let sourceRecordID = try publication.sourceRecordID(ordinal: 0, evidence: prepared.retryEvidence)

        let receipt = try #require(try await Self.upload([report], publication: publication))

        #expect(uploads.all.map(\.path) == [Self.batchFilePath(of: [sourceRecordID])])
        #expect(try uploads.entries.map(\.path) == ["recordings/\(sourceRecordID.value).json", "bundles.json", "batchinfo.json"])
        #expect(try uploads.recordings["recordings/\(sourceRecordID.value).json"] == prepared.nativePayload)
        let info = try #require(try uploads.archives.first).info
        #expect(info.source == .sensorKit)
        #expect(info.sampleTypeId == Sensor.deviceUsage.id)
        #expect(info.numRecords == 1)
        #expect(info.numSamples == 1)
        #expect(info.startDate == Self.timestamp)
        #expect(info.endDate == Self.timestamp.addingTimeInterval(600))
        let graphs = try uploads.graphs
        #expect(graphs.count == 1)
        #expect(try stagedEvent(try #require(graphs.first)).sequence.rawValue == "1")
        #expect(try ledger.reservationCount == 1)
        receipt.release()
        #expect(try ledger.reservationCount == 0)
    }

    /// Until its receipt is released, a redelivery of the batch, even from another publication at a later instant,
    /// stages the same bytes under the same name; afterwards the batch is a new event.
    @Test
    func redeliveryBeforeAcknowledgementRestatesTheBatch() async throws {
        let reports = [Self.report(), Self.report(textInputSessionIdentifier: "text-session-3")]
        let first = try await Self.upload(reports, publication: publication())
        let firstGraphs = try uploads.graphs

        let redelivered = RecordedSensorKitUploads()
        let redelivery = try await Self.upload(
            reports,
            publication: publication(uploads: redelivered, at: Self.timestamp.addingTimeInterval(3_600))
        )
        #expect(uploads.all.count == 1)
        #expect(firstGraphs.count == 2)
        #expect(redelivered.all == uploads.all)
        #expect(try ledger.reservationCount == 2)

        first?.release()
        redelivery?.release()
        #expect(try ledger.reservationCount == 0)
        let later = RecordedSensorKitUploads()
        _ = try await Self.upload(reports, publication: publication(uploads: later))
        #expect(later.all.map(\.path) == uploads.all.map(\.path))
        let laterGraphs = try later.graphs
        #expect(laterGraphs.count == firstGraphs.count)
        for (json, firstJSON) in zip(laterGraphs, firstGraphs) {
            #expect(try stagedEvent(json) != stagedEvent(firstJSON))
        }
    }

    /// Publishing a batch rewrites its retry state as often for many records as for one, and an empty batch neither
    /// fences nor touches it.
    @Test
    func batchRewritesItsRetryStateIndependentlyOfItsSize() async throws {
        func transactions(publishing reports: [SRDeviceUsageReport.SafeRepresentation]) async throws -> Int {
            let before = store.storageTransactionCountForTesting
            let receipt = try await Self.upload(reports, publication: publication(uploads: RecordedSensorKitUploads()))
            receipt?.release()
            return store.storageTransactionCountForTesting - before
        }
        let reports = (0..<8).map { Self.report(textInputSessionIdentifier: "text-session-\($0 + 10)") }

        let single = try await transactions(publishing: [reports[0]])
        #expect(single > 0)
        #expect(try await transactions(publishing: reports) == single)
        #expect(try publication(accountDataGeneration: accountDataGeneration + 1).sourceRecordIDs(of: []).isEmpty)
        #expect(store.storageTransactionCountForTesting == 2 * single)
    }

    /// A record whose bytes changed at its coordinate fails the batch before anything is exported or written.
    @Test
    func driftFailsTheBatchBeforeAnythingIsExported() async throws {
        _ = try await Self.upload([Self.report()], publication: publication())
        let writes = uploads.all
        let drifted = RecordedSensorKitUploads()

        await #expect(throws: FHIRExchangeStateError.self) {
            _ = try await Self.upload(
                [Self.report(textInputSessionIdentifier: "changed-session")],
                publication: publication(uploads: drifted)
            )
        }
        #expect(drifted.all.isEmpty)
        #expect(uploads.all == writes)
        #expect(try ledger.reservationCount == 1)
    }

    /// A batch whose staging fails keeps its events reserved, so its redelivery stages the same bytes.
    @Test
    func failedStagingKeepsTheBatchsEventsForItsRedelivery() async throws {
        let failing = RecordedSensorKitUploads(failingStaging: true)
        await #expect(throws: RecordedSensorKitUploads.StageFailure.self) {
            _ = try await Self.upload([Self.report()], publication: publication(uploads: failing))
        }
        #expect(try ledger.reservationCount == 1)

        let receipt = try await Self.upload([Self.report()], publication: publication())
        #expect(uploads.all == failing.all)
        receipt?.release()
        #expect(try ledger.reservationCount == 0)
    }

    /// Every redelivery states the zone the batch was first published in, whatever the current zone is.
    @Test
    func batchStatesTheZoneItWasFirstPublishedIn() async throws {
        let publication = try publication()
        let first = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        #expect(try publication.sourceTimeZone(current: first) == first)
        #expect(try publication.sourceTimeZone(current: .gmt) == first)

        let receipt = try await Self.upload([Self.report()], publication: publication)
        let json = try #require(try uploads.graphs.first)
        #expect(String(decoding: json, as: UTF8.self).contains("+14:00"))
        receipt?.release()

        try store.completeSensorBatch(publication.batchKey)
        #expect(try publication.sourceTimeZone(current: .gmt) == .gmt)
    }
}


// MARK: Refusals

extension DeviceUsageFHIRExchangeTests {
    /// A record Grove refuses between two it exports is skipped alone: each exported record keeps the identity and
    /// graph of its own position in the batch.
    @Test
    func refusalWithinABatchSkipsOnlyThatRecord() async throws {
        let publication = try publication()
        let first = Self.report()
        let third = Self.report(textInputSessionIdentifier: "text-session-9")
        let receipt = try await Self.upload([first, Self.refusedReport, third], publication: publication)

        var sourceRecordIDs: [SensorKitSourceRecordID] = []
        var recordings: [String: Data] = [:]
        for (ordinal, report) in [(0, first), (2, third)] {
            let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
            let sourceRecordID = try publication.sourceRecordID(ordinal: ordinal, evidence: prepared.retryEvidence)
            sourceRecordIDs.append(sourceRecordID)
            recordings["recordings/\(sourceRecordID.value).json"] = try #require(prepared.nativePayload)
        }
        #expect(uploads.all.map(\.path) == [Self.batchFilePath(of: sourceRecordIDs)])
        #expect(try uploads.graphs.count == 2)
        #expect(try uploads.recordings == recordings)
        #expect(try ledger.reservationCount == 2)
        receipt?.release()
        #expect(try ledger.reservationCount == 0)
    }

    /// A record that never prepared is refused alone, so the batch still publishes its other records.
    @Test
    func recordThatNeverPreparedIsRefusedAlone() async throws {
        let publication = try publication()
        let report = Self.report()
        let receipt = try await Self.upload([Self.unpreparableReport, report], publication: publication)

        let sourceRecordID = try publication.sourceRecordID(
            ordinal: 1,
            evidence: try SensorKitPreparedStructuredRecord(deviceUsage: report).retryEvidence
        )
        #expect(uploads.all.map(\.path) == [Self.batchFilePath(of: [sourceRecordID])])
        #expect(try uploads.graphs.count == 1)
        receipt?.release()
    }

    /// A record that no longer prepares where an earlier attempt prepared it fails its batch as drift: skipping it
    /// would acknowledge the batch without the record an earlier attempt may have staged.
    @Test
    func recordThatNoLongerPreparesFailsItsBatch() async throws {
        let failing = RecordedSensorKitUploads(failingStaging: true)
        await #expect(throws: RecordedSensorKitUploads.StageFailure.self) {
            _ = try await Self.upload([Self.report()], publication: publication(uploads: failing))
        }
        #expect(failing.all.count == 1)

        let redelivered = RecordedSensorKitUploads()
        let redelivery = try publication(uploads: redelivered)
        let sourceRecordID = try redelivery.sourceRecordID(
            ordinal: 0,
            evidence: try SensorKitPreparedStructuredRecord(deviceUsage: Self.report()).retryEvidence
        )
        await #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceRecordID.value)) {
            _ = try await Self.upload([Self.unpreparableReport], publication: redelivery)
        }
        #expect(redelivered.all.isEmpty)
        #expect(try ledger.reservationCount == 1)
    }
}
