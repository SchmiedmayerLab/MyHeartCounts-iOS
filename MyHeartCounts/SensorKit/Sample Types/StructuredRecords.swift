//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit


private struct DeviceUsageNativeReport: Encodable {
    struct ApplicationUsage: Encodable {
        struct SupplementalCategory: Encodable {
            let identifier: String
        }

        struct TextInputSession: Encodable {
            let duration: TimeInterval
            let sessionTypeRawValue: Int
            let identifier: String
        }

        let bundleIdentifier: String?
        let reportApplicationIdentifier: String
        let relativeStartTime: TimeInterval
        let usageTime: TimeInterval
        let supplementalCategories: [SupplementalCategory]
        let textInputSessions: [TextInputSession]

        init(_ usage: SRDeviceUsageReport.SafeRepresentation.AppUsage) {
            bundleIdentifier = usage.bundleIdentifier
            reportApplicationIdentifier = usage.reportApplicationIdentifier
            relativeStartTime = usage.relativeStartTime
            usageTime = usage.usageTime
            supplementalCategories = usage.supplementalCategories
                .map { SupplementalCategory(identifier: $0.identifier) }
                .sorted { $0.identifier < $1.identifier }
            textInputSessions = usage.textInputSessions.map {
                TextInputSession(
                    duration: $0.duration,
                    sessionTypeRawValue: $0.sessionType.rawValue,
                    identifier: $0.identifier
                )
            }
        }
    }

    struct NotificationUsage: Encodable {
        let bundleIdentifier: String?
        let eventRawValue: Int
    }

    struct WebUsage: Encodable {
        let totalUsageTime: TimeInterval
    }

    let timestamp: Date
    let duration: TimeInterval
    let totalScreenWakes: Int
    let totalUnlocks: Int
    let totalUnlockDuration: TimeInterval
    let version: String
    let appUsageByCategory: [String: [ApplicationUsage]]
    let notificationUsageByCategory: [String: [NotificationUsage]]
    let webUsageByCategory: [String: [WebUsage]]

    init(_ report: SRDeviceUsageReport.SafeRepresentation) {
        timestamp = report.timestamp
        duration = report.duration
        totalScreenWakes = report.totalScreenWakes
        totalUnlocks = report.totalUnlocks
        totalUnlockDuration = report.totalUnlockDuration
        version = report.version
        appUsageByCategory = Dictionary(uniqueKeysWithValues: report.appUsageByCategory.map { category, usages in
            (category.rawValue, usages.map(ApplicationUsage.init))
        })
        notificationUsageByCategory = Dictionary(
            uniqueKeysWithValues: report.notificationUsageByCategory.map { category, usages in
                (category.rawValue, usages.map {
                    NotificationUsage(
                        bundleIdentifier: $0.bundleIdentifier,
                        eventRawValue: $0.event.rawValue
                    )
                })
            }
        )
        webUsageByCategory = Dictionary(uniqueKeysWithValues: report.webUsageByCategory.map { category, usages in
            (category.rawValue, usages.map { WebUsage(totalUsageTime: $0.totalUsageTime) })
        })
    }
}


extension SRVisit.SafeRepresentation: GroveStructuredSensorSample {
    private struct RetryEvidence: Encodable {
        let timestamp: Date
        let locationID: UUID
        let distanceFromHome: Double
        let arrivalStart: Date
        let arrivalEnd: Date
        let departureStart: Date
        let departureEnd: Date
        let locationCategory: Int
    }

    func groveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        nativeRecording: @autoclosure () throws -> SensorKitNativeRecording
    ) throws -> SensorKitRecord {
        // Preserve the native location id under the deployment-scoped identifier system supplied
        // by the conversion context; it remains an identifier-only Location reference.
        .visit(try SensorKitVisitRecord(
            sourceRecordID: sourceRecordID,
            visit: self,
            locationID: locationId
        ))
    }

    func retryEvidence() throws -> Data {
        try canonicalSensorEvidence(RetryEvidence(
            timestamp: timestamp,
            locationID: locationId,
            distanceFromHome: distanceFromHome,
            arrivalStart: arrivalDateInterval.start,
            arrivalEnd: arrivalDateInterval.end,
            departureStart: departureDateInterval.start,
            departureEnd: departureDateInterval.end,
            locationCategory: locationCategory.rawValue
        ))
    }
}


extension SensorKitOnWristEventSample: GroveStructuredSensorSample {
    private struct RetryEvidence: Encodable {
        let timestamp: Date
        let onWrist: Bool
        let wristLocation: Int
        let crownOrientation: Int
        let onWristDate: Date?
        let offWristDate: Date?
    }

    func groveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        nativeRecording: @autoclosure () throws -> SensorKitNativeRecording
    ) throws -> SensorKitRecord {
        // Grove refuses a missing state start or an unrecognised wrist rather than substituting one.
        .onWrist(try SensorKitOnWristRecord(
            sourceRecordID: sourceRecordID,
            sample: self
        ))
    }

    func retryEvidence() throws -> Data {
        try canonicalSensorEvidence(RetryEvidence(
            timestamp: timestamp,
            onWrist: onWrist,
            wristLocation: wristLocation.rawValue,
            crownOrientation: crownOrientation.rawValue,
            onWristDate: onWristDate,
            offWristDate: offWristDate
        ))
    }
}


extension SRDeviceUsageReport.SafeRepresentation: GroveStructuredSensorSample {
    static var carriesNativeRecording: Bool { true }

    func groveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        nativeRecording: @autoclosure () throws -> SensorKitNativeRecording
    ) throws -> SensorKitRecord {
        .deviceUsage(SensorKitDeviceUsageRecord(
            sourceRecordID: sourceRecordID,
            report: self,
            nativeRecording: try nativeRecording()
        ))
    }

    func nativePayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(DeviceUsageNativeReport(self))
    }

    func retryEvidence() throws -> Data {
        try nativePayload()
    }
}


private func canonicalSensorEvidence(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(value)
}
