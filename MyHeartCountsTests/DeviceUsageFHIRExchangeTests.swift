//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
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


@Suite
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
    private let uploads = RecordedSensorKitUploads()

    init() {
        store = FHIRExchangeStateStore(accountDataGeneration: accountDataGeneration)
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
    ) async throws {
        try await UploadStrategyStructured<SRDeviceUsageReport>().upload(
            reports,
            publication: publication,
            for: Sensor.deviceUsage,
            activity: SensorKitDataFetcher.InProgressActivity(sensor: Sensor.deviceUsage)
        )
    }

    /// The remote path of the batch archive that publishes `records`.
    static func batchFilePath(of records: [ExchangeRecord]) -> String {
        ManagedFileUpload.Category(Sensor.deviceUsage).remotePath(for: HealthUploadBatch.filename(
            typePrefix: Sensor.deviceUsage.id,
            provenanceFullURLs: records.map(\.version.fullURL),
            fileExtension: "zip"
        ))
    }

    /// The path a record's JSON recording has in its archive: the lowercase hex SHA-256 of its bytes.
    static func recordingPath(of payload: Data) -> String {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return "recordings/\(digest).json"
    }

    /// The SensorKit source-record identifiers a graph discloses, under the repository's own native record system.
    static func nativeRecordIDs(in json: Data) throws -> Set<String> {
        let system = "\(FHIRExchangeIdentifiers.sensorKitSourceRecord.rawValue)/"
        return Set(try statedIdentifiers(in: json).filter { $0.system.hasPrefix(system) }.map(\.value))
    }

    /// The publication production builds, so its account fence, ordinal-derived source ids, retry state and exporter
    /// are the ones under test rather than a copy of them.
    private func publication(
        accountDataGeneration: Int? = nil,
        uploads: RecordedSensorKitUploads? = nil,
        at conversionInstant: Date = DeviceUsageFHIRExchangeTests.timestamp,
        facts: MyHeartCounts::ConversionFacts? = nil
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
            uploader: (uploads ?? self.uploads).uploader,
            conversionInstant: conversionInstant,
            currentFacts: {
                try facts ?? .testing()
            }
        )
    }

    @Test
    func nestedDeviceUsageDriftCannotReuseAnIdentity() throws {
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

    /// A refused record stages nothing, and the batch it belongs to still completes.
    @Test
    func refusedRecordsDoNotFailTheirBatch() async throws {
        try await Self.upload([Self.refusedReport, Self.refusedReport], publication: publication())

        #expect(uploads.all.isEmpty)
    }

    @Test
    func accountFenceAbortsBatchInsteadOfRefusingRecord() async throws {
        let publication = try publication(accountDataGeneration: accountDataGeneration + 1)

        await #expect(throws: FHIRExchangeDestinationError.accountChanged) {
            try await Self.upload([Self.refusedReport], publication: publication)
        }
    }

    @Test
    func deviceUsageBundleCarriesMandatoryNativeRecordingDocument() async throws {
        let publication = try publication()
        let report = Self.report()
        let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
        let payload = try #require(prepared.nativePayload)
        let recordingPath = Self.recordingPath(of: payload)

        try await Self.upload([report], publication: publication)
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: try #require(try uploads.bundles.first))
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
    }
}


// MARK: Publication

extension DeviceUsageFHIRExchangeTests {
    /// The batch is staged as one archive, named by the Provenances of its records, holding its one Bundle, each record's
    /// recording, and the batch's info; each record's version is keyed under the store's key for the batch's subject.
    @Test
    func publishedBatchStagesOneArchiveOfItsBundleAndRecordings() async throws {
        let publication = try publication()
        let report = Self.report()
        let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
        let payload = try #require(prepared.nativePayload)
        let sourceRecordID = try publication.sourceRecordID(ordinal: 0, evidence: prepared.retryEvidence)
        let recordingPath = Self.recordingPath(of: payload)

        try await Self.upload([report], publication: publication)

        let records = try uploads.records
        #expect(uploads.all.map(\.path) == [Self.batchFilePath(of: records)])
        #expect(try uploads.entries.map(\.path) == [recordingPath, "bundle.json", "batchinfo.json"])
        #expect(try uploads.recordings[recordingPath] == payload)
        // The file's metadata carries the archive's batch info, byte for byte.
        let batchInfo = try #require(try uploads.entries.first { $0.path == "batchinfo.json" }).contents
        #expect(uploads.all.map(\.metadata) == [[UploadBatchArchive.batchInfoMetadataKey: String(decoding: batchInfo, as: UTF8.self)]])
        let info = try #require(try uploads.archives.first).info
        #expect(info.source == .sensorKit)
        #expect(info.sampleTypeId == Sensor.deviceUsage.id)
        #expect(info.numRecords == 1)
        #expect(info.numSamples == 1)
        #expect(info.startDate == Self.timestamp)
        // The report's own span, which its duration ends, rather than the fetched batch's.
        #expect(info.endDate == Self.timestamp.addingTimeInterval(600.25))
        #expect(info.device == publication.info.device.productType)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(try Self.nativeRecordIDs(in: record.json) == [sourceRecordID.value])
        try record.verifyVersion(in: store.identityScope(subject: Self.subject))
    }

    /// Until its cursor is acknowledged, a redelivery of the batch, even from another publication at a later instant, restates
    /// every record version, byte for byte and under the same name. Once it is acknowledged, its retry state is gone, so a
    /// later delivery at its coordinates is a new version of each of its source records.
    @Test
    func redeliveryBeforeAcknowledgementRestatesTheBatch() async throws {
        let reports = [Self.report(), Self.report(textInputSessionIdentifier: "text-session-3")]
        let laterInstant = Self.timestamp.addingTimeInterval(3_600)
        let first = try publication()
        try await Self.upload(reports, publication: first)
        let firstRecords = try uploads.records

        let redelivered = RecordedSensorKitUploads()
        try await Self.upload(reports, publication: publication(uploads: redelivered, at: laterInstant))
        #expect(uploads.all.count == 1)
        #expect(firstRecords.count == 2)
        #expect(redelivered.all == uploads.all)
        #expect(try redelivered.records.map(\.version) == firstRecords.map(\.version))

        try store.completeSensorBatch(first.batchKey)
        let later = RecordedSensorKitUploads()
        try await Self.upload(reports, publication: publication(uploads: later, at: laterInstant))
        #expect(later.all.map(\.path) != uploads.all.map(\.path))
        let laterRecords = try later.records
        #expect(laterRecords.map(\.sourceRecord) == firstRecords.map(\.sourceRecord))
        #expect(laterRecords.count == firstRecords.count)
        for (record, firstRecord) in zip(laterRecords, firstRecords) {
            #expect(record.version != firstRecord.version)
        }
    }

    /// A batch states the conversion instant it was first published at on every redelivery, whatever instant its own
    /// publication was made at; the instant goes with the batch's retry state.
    @Test
    func batchStatesTheInstantItWasFirstPublishedAt() async throws {
        let laterInstant = Self.timestamp.addingTimeInterval(3_600)
        let first = try publication()
        let redelivery = try publication(at: laterInstant)
        #expect(try await first.batchFacts().conversionInstant == Self.timestamp)
        #expect(try await redelivery.batchFacts().conversionInstant == Self.timestamp)

        try store.completeSensorBatch(first.batchKey)
        #expect(try await redelivery.batchFacts().conversionInstant == laterInstant)
    }

    /// Records with the same bytes at two coordinates are both published over one recording: its name follows from its
    /// bytes, and an archive writes a name once.
    @Test
    func aRecordingNameIsWrittenOnce() async throws {
        let report = Self.report()
        let payload = try #require(try SensorKitPreparedStructuredRecord(deviceUsage: report).nativePayload)
        let recordingPath = Self.recordingPath(of: payload)

        try await Self.upload([report, report], publication: publication())

        #expect(try uploads.entries.map(\.path) == [recordingPath, "bundle.json", "batchinfo.json"])
        #expect(try uploads.recordings == [recordingPath: payload])
        #expect(try uploads.archives.first?.info.numRecords == 2)
        #expect(try Set(uploads.records.map(\.sourceRecord)).count == 2)
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: try #require(try uploads.bundles.first))
        let documents = bundle.entry?.compactMap { $0.resource?.get(if: DocumentReference.self) } ?? []
        #expect(documents.compactMap { $0.content.first?.attachment.url?.value?.url.absoluteString } == [recordingPath, recordingPath])
    }

    /// A record discloses its SensorKit source-record identifier as its native identifier, and no name the batch travels
    /// under carries it.
    @Test
    func namesCarryNoSourceRecordIdentifier() async throws {
        let publication = try publication()
        let report = Self.report()
        let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
        let sourceRecordID = try publication.sourceRecordID(ordinal: 0, evidence: prepared.retryEvidence)

        try await Self.upload([report], publication: publication)

        let names = try uploads.all.map(\.path) + uploads.entries.map(\.path)
        #expect(names.count == 4)
        #expect(!names.contains { $0.lowercased().contains(sourceRecordID.value.lowercased()) })
        let bundle = try #require(try uploads.bundles.first)
        #expect(try Self.nativeRecordIDs(in: bundle) == [sourceRecordID.value])
    }

    /// Publishing a batch rewrites its retry state as often for many records as for one, and an empty batch neither
    /// fences nor touches it.
    @Test
    func batchRewritesItsRetryStateIndependentlyOfItsSize() async throws {
        func transactions(publishing reports: [SRDeviceUsageReport.SafeRepresentation]) async throws -> Int {
            let before = store.storageTransactionCountForTesting
            try await Self.upload(reports, publication: publication(uploads: RecordedSensorKitUploads()))
            return store.storageTransactionCountForTesting - before
        }
        let reports = (0..<8).map { Self.report(textInputSessionIdentifier: "text-session-\($0 + 10)") }

        let single = try await transactions(publishing: [reports[0]])
        #expect(single > 0)
        #expect(try await transactions(publishing: reports) == single)
        #expect(try publication(accountDataGeneration: accountDataGeneration + 1).sourceRecordIDs(of: []).isEmpty)
        #expect(store.storageTransactionCountForTesting == 2 * single)
    }

    /// A record whose bytes changed at its coordinate fails the batch before anything is exported or written, and the
    /// batch stays as it was first published.
    @Test
    func driftFailsTheBatchBeforeAnythingIsExported() async throws {
        try await Self.upload([Self.report()], publication: publication())
        let writes = uploads.all
        let drifted = RecordedSensorKitUploads()

        await #expect(throws: FHIRExchangeStateError.self) {
            try await Self.upload(
                [Self.report(textInputSessionIdentifier: "changed-session")],
                publication: publication(uploads: drifted)
            )
        }
        #expect(drifted.all.isEmpty)
        #expect(uploads.all == writes)

        let redelivered = RecordedSensorKitUploads()
        try await Self.upload([Self.report()], publication: publication(uploads: redelivered))
        #expect(redelivered.all == writes)
    }

    /// A batch whose staging fails keeps its retry state, so its redelivery, at a later instant, stages the same bytes.
    @Test
    func failedStagingKeepsTheBatchForItsRedelivery() async throws {
        let failing = RecordedSensorKitUploads(failingStaging: true)
        await #expect(throws: RecordedSensorKitUploads.StageFailure.self) {
            try await Self.upload([Self.report()], publication: publication(uploads: failing))
        }

        try await Self.upload([Self.report()], publication: publication(at: Self.timestamp.addingTimeInterval(3_600)))
        #expect(uploads.all == failing.all)
    }

    /// Every redelivery states the zone the batch was first published in, whatever the current zone is.
    @Test
    func batchStatesTheZoneItWasFirstPublishedIn() async throws {
        let publication = try publication()
        let first = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        #expect(try await publication.batchFacts(currentTimeZone: first).timeZone == first)
        #expect(try await publication.batchFacts(currentTimeZone: .gmt).timeZone == first)

        try await Self.upload([Self.report()], publication: publication)
        let json = try #require(try uploads.graphs.first)
        #expect(String(decoding: json, as: UTF8.self).contains("+14:00"))

        try store.completeSensorBatch(publication.batchKey)
        #expect(try await publication.batchFacts(currentTimeZone: .gmt).timeZone == .gmt)
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
        try await Self.upload([first, Self.refusedReport, third], publication: publication)

        var sourceRecordIDs: [SensorKitSourceRecordID] = []
        var recordings: [String: Data] = [:]
        for (ordinal, report) in [(0, first), (2, third)] {
            let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
            sourceRecordIDs.append(try publication.sourceRecordID(ordinal: ordinal, evidence: prepared.retryEvidence))
            let payload = try #require(prepared.nativePayload)
            recordings[Self.recordingPath(of: payload)] = payload
        }
        let records = try uploads.records
        #expect(uploads.all.map(\.path) == [Self.batchFilePath(of: records)])
        #expect(try records.map { try Self.nativeRecordIDs(in: $0.json) } == sourceRecordIDs.map { [$0.value] })
        #expect(try uploads.recordings == recordings)
    }

    /// A record that never prepared is refused alone, so the batch still publishes its other records.
    @Test
    func recordThatNeverPreparedIsRefusedAlone() async throws {
        let publication = try publication()
        let report = Self.report()
        try await Self.upload([Self.unpreparableReport, report], publication: publication)

        let sourceRecordID = try publication.sourceRecordID(
            ordinal: 1,
            evidence: try SensorKitPreparedStructuredRecord(deviceUsage: report).retryEvidence
        )
        let records = try uploads.records
        #expect(uploads.all.map(\.path) == [Self.batchFilePath(of: records)])
        #expect(try records.map { try Self.nativeRecordIDs(in: $0.json) } == [[sourceRecordID.value]])
    }

    /// A record that no longer prepares where an earlier attempt prepared it fails its batch as drift: skipping it
    /// would acknowledge the batch without the record an earlier attempt may have staged.
    @Test
    func recordThatNoLongerPreparesFailsItsBatch() async throws {
        let failing = RecordedSensorKitUploads(failingStaging: true)
        await #expect(throws: RecordedSensorKitUploads.StageFailure.self) {
            try await Self.upload([Self.report()], publication: publication(uploads: failing))
        }
        #expect(failing.all.count == 1)

        let redelivered = RecordedSensorKitUploads()
        let redelivery = try publication(uploads: redelivered)
        let sourceRecordID = try redelivery.sourceRecordID(
            ordinal: 0,
            evidence: try SensorKitPreparedStructuredRecord(deviceUsage: Self.report()).retryEvidence
        )
        await #expect(throws: FHIRExchangeStateError.retryContentChanged(sourceRecordID: sourceRecordID.value)) {
            try await Self.upload([Self.unpreparableReport], publication: redelivery)
        }
        #expect(redelivered.all.isEmpty)
    }
}
