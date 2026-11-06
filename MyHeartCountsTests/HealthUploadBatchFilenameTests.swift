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
    private static let first = "urn:uuid:00000000-0000-5000-8000-000000000001"
    private static let second = "urn:uuid:00000000-0000-5000-8000-000000000002"

    @Test
    func filenameIsStableAcrossInputOrderAndUsesABoundedDigest() {
        let forward = HealthUploadBatch.filename(
            typePrefix: "HKQuantityTypeIdentifierStepCount",
            provenanceFullURLs: [Self.first, Self.second],
            fileExtension: "json.zstd"
        )
        let reverse = HealthUploadBatch.filename(
            typePrefix: "HKQuantityTypeIdentifierStepCount",
            provenanceFullURLs: [Self.second, Self.first],
            fileExtension: "json.zstd"
        )

        // The filename is the cross-version dedup key for staged uploads, so it is pinned exactly.
        #expect(forward == "HKQuantityTypeIdentifierStepCount_45256bd0327cd1708ce2c81a.json.zstd")
        #expect(forward == reverse)
    }

    @Test
    func filenameChangesWhenBatchMembershipChanges() {
        let oneFullURL = HealthUploadBatch.filename(
            typePrefix: "type",
            provenanceFullURLs: [Self.first],
            fileExtension: "json.zstd"
        )
        let twoFullURLs = HealthUploadBatch.filename(
            typePrefix: "type",
            provenanceFullURLs: [Self.first, Self.second],
            fileExtension: "json.zstd"
        )

        #expect(oneFullURL != twoFullURLs)
    }
}
