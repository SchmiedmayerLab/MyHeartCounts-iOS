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


extension SRVisit.SafeRepresentation: GroveStructuredSensorSample {
    var groveRecordID: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(timestamp)
        hasher.combine(locationId)
        hasher.combine(distanceFromHome)
        hasher.combine(arrivalDateInterval.start)
        hasher.combine(arrivalDateInterval.end)
        hasher.combine(departureDateInterval.start)
        hasher.combine(departureDateInterval.end)
        hasher.combine(locationCategory.rawValue)
        return hasher.finalize()
    }

    func groveRecord(recordID: UUID, nativeRecording: @autoclosure () throws -> SensorKitNativeRecording) throws -> SensorKitRecord {
        // Supplied rather than dropped here; whether it reaches FHIR is the conversion context's
        // ``SensorKitLinkableIdentifierPolicy`` to decide.
        .visit(try SensorKitVisitRecord(
            sourceRecordID: SensorKitSourceRecordID(recordID),
            visit: self,
            locationID: locationId
        ))
    }
}


extension SensorKitOnWristEventSample: GroveStructuredSensorSample {
    var groveRecordID: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(timestamp)
        hasher.combine(onWrist ? 1 : 0)
        hasher.combine(wristLocation.rawValue)
        hasher.combine(crownOrientation.rawValue)
        hasher.combine(onWristDate?.timeIntervalSince1970.bitPattern ?? 0)
        hasher.combine(offWristDate?.timeIntervalSince1970.bitPattern ?? 0)
        return hasher.finalize()
    }

    func groveRecord(recordID: UUID, nativeRecording: @autoclosure () throws -> SensorKitNativeRecording) throws -> SensorKitRecord {
        // Grove refuses a missing state start or an unrecognised wrist rather than substituting one.
        .onWrist(try SensorKitOnWristRecord(
            sourceRecordID: SensorKitSourceRecordID(recordID),
            sample: self
        ))
    }
}


extension SRDeviceUsageReport.SafeRepresentation: GroveStructuredSensorSample {
    private struct NativeReport: Encodable {
        struct AppUsage: Encodable {
            let category: String
            let bundleIdentifier: String?
            let reportApplicationIdentifier: String
            let relativeStartTime: TimeInterval
            let usageTimeSeconds: TimeInterval
            let supplementalCategories: [String]
        }

        struct NotificationUsage: Encodable {
            let category: String
            let bundleIdentifier: String?
            let event: Int
        }

        struct WebUsage: Encodable {
            let category: String
            let totalUsageTimeSeconds: TimeInterval
        }

        let version: String
        let appUsage: [AppUsage]
        let notificationUsage: [NotificationUsage]
        let webUsage: [WebUsage]

        // Sorted rather than in dictionary order: the record identity is derived from these bytes,
        // so an unordered walk would give the same report a different identity on every run.
        init(_ report: SRDeviceUsageReport.SafeRepresentation) {
            version = report.version
            appUsage = report.appUsageByCategory.flatMap { category, usages in
                usages.map { usage in
                    AppUsage(
                        category: category.rawValue,
                        bundleIdentifier: usage.bundleIdentifier,
                        reportApplicationIdentifier: usage.reportApplicationIdentifier,
                        relativeStartTime: usage.relativeStartTime,
                        usageTimeSeconds: usage.usageTime,
                        supplementalCategories: usage.supplementalCategories.map(\.identifier).sorted()
                    )
                }
            }
            .sorted {
                ($0.category, $0.reportApplicationIdentifier, $0.relativeStartTime)
                    < ($1.category, $1.reportApplicationIdentifier, $1.relativeStartTime)
            }
            notificationUsage = report.notificationUsageByCategory.flatMap { category, usages in
                usages.map { NotificationUsage(category: category.rawValue, bundleIdentifier: $0.bundleIdentifier, event: $0.event.rawValue) }
            }
            .sorted { ($0.category, $0.bundleIdentifier ?? "", $0.event) < ($1.category, $1.bundleIdentifier ?? "", $1.event) }
            webUsage = report.webUsageByCategory.flatMap { category, usages in
                usages.map { WebUsage(category: category.rawValue, totalUsageTimeSeconds: $0.totalUsageTime) }
            }
            .sorted { ($0.category, $0.totalUsageTimeSeconds) < ($1.category, $1.totalUsageTimeSeconds) }
        }
    }

    // The per-application, notification, and web breakdowns have no structured contract, so they
    // ride along byte-exact as the graph's native recording.
    static var carriesNativeRecording: Bool { true }

    var groveRecordID: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(timestamp)
        hasher.combine(duration)
        hasher.combine(totalScreenWakes)
        hasher.combine(totalUnlocks)
        hasher.combine(totalUnlockDuration)
        hasher.combine(version)
        // The breakdowns, not their counts: reports agreeing on every total but differing inside
        // them would otherwise share an identity, and the sidecar written under it would be lost.
        let report = NativeReport(self)
        for usage in report.appUsage {
            hasher.combine(usage.category)
            hasher.combine(usage.bundleIdentifier ?? "")
            hasher.combine(usage.reportApplicationIdentifier)
            hasher.combine(usage.relativeStartTime)
            hasher.combine(usage.usageTimeSeconds)
            usage.supplementalCategories.forEach { hasher.combine($0) }
        }
        for usage in report.notificationUsage {
            hasher.combine(usage.category)
            hasher.combine(usage.bundleIdentifier ?? "")
            hasher.combine(usage.event)
        }
        for usage in report.webUsage {
            hasher.combine(usage.category)
            hasher.combine(usage.totalUsageTimeSeconds)
        }
        return hasher.finalize()
    }

    func groveRecord(recordID: UUID, nativeRecording: @autoclosure () throws -> SensorKitNativeRecording) throws -> SensorKitRecord {
        .deviceUsage(SensorKitDeviceUsageRecord(
            sourceRecordID: SensorKitSourceRecordID(recordID),
            report: self,
            nativeRecording: try nativeRecording()
        ))
    }

    func nativePayload() throws -> Data {
        try JSONEncoder().encode(NativeReport(self))
    }
}
