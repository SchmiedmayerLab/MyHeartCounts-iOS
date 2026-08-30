//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import SensorKit
import Testing


@Suite
struct HealthUploadBatchFilenameTests {
    @Test
    func filenameIsStableAcrossInputOrderAndUsesABoundedDigest() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        let forward = HealthUploadBatchFilename.make(
            typePrefix: "HKQuantityTypeIdentifierStepCount",
            identifiers: [first, second],
            fileExtension: "json.zstd"
        )
        let reverse = HealthUploadBatchFilename.make(
            typePrefix: "HKQuantityTypeIdentifierStepCount",
            identifiers: [second, first],
            fileExtension: "json.zstd"
        )

        #expect(forward == reverse)
        #expect(forward.hasPrefix("HKQuantityTypeIdentifierStepCount_"))
        #expect(forward.hasSuffix(".json.zstd"))
        let digest = try #require(forward.split(separator: "_").last?.split(separator: ".").first)
        #expect(digest.count == 24)
        #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test
    func filenameChangesWhenBatchMembershipChanges() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        let oneIdentifier = HealthUploadBatchFilename.make(
            typePrefix: "type",
            identifiers: [first],
            fileExtension: "json.zstd"
        )
        let twoIdentifiers = HealthUploadBatchFilename.make(
            typePrefix: "type",
            identifiers: [first, second],
            fileExtension: "json.zstd"
        )

        #expect(oneIdentifier != twoIdentifiers)
    }

    @Test
    func wristTemperatureConditionsRejectUnknownBits() throws {
        let known = SRWristTemperature.Condition.offWrist.union(.inMotion)
        #expect(try known.csvStringValue() == "offWrist,inMotion")

        let unknown = SRWristTemperature.Condition(rawValue: 1 << 12)
        #expect(throws: SensorKitUploadError.self) {
            _ = try unknown.csvStringValue()
        }
    }

    @Test
    func accelerometerBatchCountUsesDistinctNativeIdentifiers() {
        let identifiers: [UInt64?] = [41, 41, 42, nil, 43, 42]

        #expect(SensorKitBatchStatistics.distinctRecordingIdentifierCount(identifiers) == 3)
    }
}
