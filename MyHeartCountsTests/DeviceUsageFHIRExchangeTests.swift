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
import SensorKit
import Synchronization
import Testing

@testable import MyHeartCounts


/// What a publication under test staged and wrote, in order.
final class RecordedSensorKitUploads: Sendable {
    enum Write: Equatable {
        /// A sidecar staged under its remote path, with its exact bytes.
        case sidecar(path: String, bytes: Data)
        /// A graph written to the document of its sample type named by its source-record identifier.
        case graph(sampleType: String, documentID: String, json: Data)
    }

    struct WriteFailure: Error {}

    private let writes = Mutex<[Write]>([])
    /// Whether writing a graph fails, after the write was recorded.
    private let failsWrites: Bool

    var all: [Write] {
        writes.withLock { $0 }
    }

    /// The graphs written, by document identifier.
    var graphs: [String: Data] {
        Dictionary(all.compactMap { write in
            guard case let .graph(_, documentID, json) = write else {
                return nil
            }
            return (documentID, json)
        }) { _, later in later }
    }

    var uploader: SensorKitRecordUploader {
        SensorKitRecordUploader { file, category, _ in
            let bytes = try Data(contentsOf: file)
            self.writes.withLock { $0.append(.sidecar(path: category.remotePath(for: file.lastPathComponent), bytes: bytes)) }
        } writeGraph: { graph, sourceRecordID, sampleType, _ in
            self.writes.withLock { $0.append(.graph(sampleType: sampleType, documentID: sourceRecordID.value, json: graph.json)) }
            if self.failsWrites {
                throw WriteFailure()
            }
        }
    }

    init(failingWrites: Bool = false) {
        self.failsWrites = failingWrites
    }
}


/// Serialized: every test publishes the same records, whose sidecars are written under their source-record identifiers.
@Suite(.serialized)
struct DeviceUsageFHIRExchangeTests {
    private static let timestamp = Date(timeIntervalSince1970: 1_788_000_000.125)

    /// A report unlocked for longer than it lasted, which Grove refuses to convert.
    private static var refusedReport: SRDeviceUsageReport.SafeRepresentation {
        report(totalUnlockDuration: 900)
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

    private static func report(
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

    private static func upload(
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

    /// A refused record reserves nothing and writes nothing, and the batch it belongs to still completes.
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
        let category = ManagedFileUpload.Category(Sensor.deviceUsage)
        let filename = "\(sourceID.value).json"
        let sidecarPath = category.remotePath(for: filename)

        let receipt = try await Self.upload([report], publication: publication)
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: try #require(uploads.graphs[sourceID.value]))
        let documents = bundle.entry?.compactMap { $0.resource?.get(if: DocumentReference.self) } ?? []
        let document = try #require(documents.first)
        let content = try #require(document.content.first)

        #expect(documents.count == 1)
        #expect(document.content.count == 1)
        #expect(content.attachment.data == nil)
        #expect(content.attachment.url?.value?.url.absoluteString == sidecarPath)
        #expect(sidecarPath == "\(category.firebasePath)/\(filename)")
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
    /// Each record's sidecar is staged before its graph is written, and the graph lands in the document its
    /// source-record identifier names; the batch's events stay reserved until its receipt is released.
    @Test
    func publishedRecordStagesItsSidecarBeforeItsGraph() async throws {
        let publication = try publication()
        let report = Self.report()
        let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
        let payload = try #require(prepared.nativePayload)
        let sourceRecordID = try publication.sourceRecordID(ordinal: 0, evidence: prepared.retryEvidence)

        let receipt = try #require(try await Self.upload([report], publication: publication))

        let writes = uploads.all
        let sidecarPath = ManagedFileUpload.Category(Sensor.deviceUsage).remotePath(for: "\(sourceRecordID.value).json")
        #expect(writes.count == 2)
        #expect(writes.first == .sidecar(path: sidecarPath, bytes: payload))
        guard case let .graph(sampleType, documentID, json)? = writes.last else {
            Issue.record("The record's graph is written after its sidecar")
            return
        }
        #expect(sampleType == Sensor.deviceUsage.id)
        #expect(documentID == sourceRecordID.value)
        #expect(try stagedEvent(json).sequence.rawValue == "1")
        #expect(try ledger.reservationCount == 1)
        receipt.release()
        #expect(try ledger.reservationCount == 0)
    }

    /// Until its receipt is released, a redelivery of the batch, even from another publication at a later instant,
    /// writes the same bytes to the same documents; afterwards the batch is a new event.
    @Test
    func redeliveryBeforeAcknowledgementRestatesTheBatch() async throws {
        let reports = [Self.report(), Self.report(textInputSessionIdentifier: "text-session-3")]
        let first = try await Self.upload(reports, publication: publication())
        let firstGraphs = uploads.graphs

        let redelivered = RecordedSensorKitUploads()
        let redelivery = try await Self.upload(
            reports,
            publication: publication(uploads: redelivered, at: Self.timestamp.addingTimeInterval(3_600))
        )
        #expect(firstGraphs.count == 2)
        #expect(redelivered.all == uploads.all)
        #expect(try ledger.reservationCount == 2)

        first?.release()
        redelivery?.release()
        #expect(try ledger.reservationCount == 0)
        let later = RecordedSensorKitUploads()
        _ = try await Self.upload(reports, publication: publication(uploads: later))
        #expect(Set(later.graphs.keys) == Set(firstGraphs.keys))
        for (documentID, json) in later.graphs {
            #expect(try stagedEvent(json) != stagedEvent(try #require(firstGraphs[documentID])))
        }
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

    /// A batch whose write fails keeps its events reserved, so its redelivery writes the same bytes.
    @Test
    func failedWriteKeepsTheBatchsEventsForItsRedelivery() async throws {
        let failing = RecordedSensorKitUploads(failingWrites: true)
        await #expect(throws: RecordedSensorKitUploads.WriteFailure.self) {
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
        let json = try #require(uploads.graphs.values.first)
        #expect(String(decoding: json, as: UTF8.self).contains("+14:00"))
        receipt?.release()

        try store.completeSensorBatch(publication.batchKey)
        #expect(try publication.sourceTimeZone(current: .gmt) == .gmt)
    }
}
