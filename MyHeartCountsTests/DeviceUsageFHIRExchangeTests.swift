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
import Testing

@testable import MyHeartCounts

@Suite
struct DeviceUsageFHIRExchangeTests {
    private static let timestamp = Date(timeIntervalSince1970: 1_788_000_000.125)

    private static func report(
        textInputSessionIdentifier: String = "text-session-1"
    ) -> SRDeviceUsageReport.SafeRepresentation {
        let applicationCategory = SRDeviceUsageReport.CategoryKey(rawValue: "application-category")
        let notificationCategory = SRDeviceUsageReport.CategoryKey(rawValue: "notification-category")
        let webCategory = SRDeviceUsageReport.CategoryKey(rawValue: "web-category")
        return SRDeviceUsageReport.SafeRepresentation(
            timestamp: timestamp,
            duration: 600.25,
            totalScreenWakes: 9,
            totalUnlocks: 7,
            totalUnlockDuration: 123.75,
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

    /// The publication production builds, so its account fence, ordinal-derived source ids, and
    /// event facts are the ones under test rather than a copy of them.
    private static func publication(
        store: FHIRExchangeStateStore = FHIRExchangeStateStore()
    ) throws -> SensorKitBatchPublication {
        let subject = try FHIRExchangeSubject(
            identity: BusinessIdentifier(
                system: FHIRExchangeIdentifiers.participant,
                value: "device-usage-test-participant"
            )
        )
        return try SensorKitBatchPublication(
            sensor: Sensor.deviceUsage,
            batchInfo: SensorKit.BatchInfo(
                timeRange: timestamp..<timestamp.addingTimeInterval(600),
                device: SensorKit.DeviceInfo(SRDevice.current),
                acquisitionBatch: SensorKit.AcquisitionBatchCoordinate(
                    cursorTimestamp: timestamp,
                    resetGeneration: 2,
                    sequence: 7
                )
            ),
            subject: subject,
            destination: FHIRExchangeDestination(
                accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration],
                accountID: subject.identity.value
            ),
            stateStore: store,
            conversionInstant: timestamp
        )
    }

    @Test
    func nestedDeviceUsageDriftCannotReuseReservedIdentity() throws {
        let publication = try Self.publication()
        let reservation = try publication.reserve(
            recordOrdinal: 0,
            evidence: try SensorKitPreparedStructuredRecord(deviceUsage: Self.report()).retryEvidence
        )

        #expect(throws: FHIRExchangeStateError.retryContentChanged(
            sourceRecordID: reservation.sourceRecordID.value
        )) {
            _ = try publication.reserve(
                recordOrdinal: 0,
                evidence: try SensorKitPreparedStructuredRecord(
                    deviceUsage: Self.report(textInputSessionIdentifier: "changed-session")
                ).retryEvidence
            )
        }
    }

    @Test
    func deviceUsageBundleCarriesMandatoryNativeRecordingDocument() throws {
        let report = Self.report()
        let prepared = try SensorKitPreparedStructuredRecord(deviceUsage: report)
        let payload = try #require(prepared.nativePayload)
        let reservation = try Self.publication().reserve(
            recordOrdinal: 0,
            evidence: prepared.retryEvidence
        )
        let sourceID = reservation.sourceRecordID
        let filename = "\(sourceID.value).json"
        let category = ManagedFileUpload.Category(Sensor.deviceUsage)
        let sidecarPath = category.remotePath(for: filename)
        let record = try prepared.sensorKitRecord(
            sourceRecordID: sourceID,
            title: "Exact SensorKit device-usage report",
            location: .sidecar(path: sidecarPath),
            admission: .callerAuthorizedOpaquePayload
        )
        let conversion = try SensorKitConverter().convert(record, context: reservation.context)
        let document = try #require(conversion.recordingDocument)
        let content = try #require(document.content.first)

        #expect(document.content.count == 1)
        #expect(content.attachment.data == nil)
        #expect(content.attachment.url?.value?.url.absoluteString == sidecarPath)
        #expect(sidecarPath == "\(category.firebasePath)/\(filename)")
        #expect(content.attachment.size?.value?.integer == Int32(payload.count))
        #expect(content.attachment.hash != nil)
        #expect(
            content.format?.code?.value?.string == RegisteredRecordingFormat.nativeRecording.rawValue
        )
        #expect(conversion.artifactIdentifiers.count == 1)

        let bundledDocuments = conversion.bundle.entry?.compactMap { entry -> DocumentReference? in
            guard case .documentReference(let document)? = entry.resource else {
                return nil
            }
            return document
        }
        #expect(bundledDocuments?.map(\.id) == [document.id])
    }
}
