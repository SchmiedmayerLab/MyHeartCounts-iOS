//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
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
}
