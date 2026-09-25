//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import GroveFoundation
@testable import MyHeartCounts
import Testing


@Suite
final class TmpTests {
    private let suiteName = "edu.stanford.MyHeartCounts.unitTests"
    private let suite: UserDefaults
    private let store: LocalPreferencesStore
    
    init() throws {
        suite = try #require(UserDefaults(suiteName: suiteName))
        store = LocalPreferencesStore(defaults: suite)
    }
    
    deinit { // swiftlint:disable:this type_contents_order
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    
    @Test
    func prefsPrefix() {
        let appNS = LocalPreferenceKeys.Namespace.app
        let appNSFmt = appNS.format(keyName: "", applyKVOCompatibilityFixes: false)
        #expect(appNSFmt == "edu.stanford.MyHeartCounts:")
        
        let nestedNS = HealthKitStatsCalculator.QueryAnchors.namespace
        let nestedNSFmt = nestedNS.format(keyName: "", applyKVOCompatibilityFixes: false)
        #expect(nestedNSFmt.hasPrefix(appNSFmt))
        
        let key = LocalPreferenceKey<String?>(.init("keyy", in: nestedNS))
        store[key] = "Hey!"
        #expect(store[key] == "Hey!")
        store.removeAllEntries(in: nestedNS)
        #expect(store[key] == nil)
        store[key] = "Hey!"
        #expect(store[key] == "Hey!")
        store.removeAllEntries(in: appNS)
        #expect(store[key] == nil)
    }
}
