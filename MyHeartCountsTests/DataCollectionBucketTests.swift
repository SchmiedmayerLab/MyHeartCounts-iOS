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
struct DataCollectionBucketTests {
    @Test
    func readsBucketFromConfig() throws {
        let url = try writeConfig(["PROJECT_ID": "test", "DATA_COLLECTION_BUCKET": "test-datacollection"])
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        #expect(DeferredConfigLoading.dataCollectionBucket(for: .customUrl(url)) == "test-datacollection")
    }

    @Test(arguments: [
        ["PROJECT_ID": "test"],
        ["PROJECT_ID": "test", "DATA_COLLECTION_BUCKET": ""]
    ])
    func missingBucketUsesDefault(config: [String: String]) throws {
        let url = try writeConfig(config)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        #expect(DeferredConfigLoading.dataCollectionBucket(for: .customUrl(url)) == nil)
    }

    private func writeConfig(_ values: [String: String]) throws -> URL {
        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
        return url
    }
}
