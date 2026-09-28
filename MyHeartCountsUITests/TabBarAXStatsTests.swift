//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import XCTest


/// Diagnostic test that measures how reliably the root tab bar's accessibility identifiers
/// show up in the XCUITest snapshot. Not part of the regular test suite semantics;
/// it launches the app repeatedly and prints AXSTATS lines with the hit rates.
final class TabBarAXStatsTests: MHCTestCase, @unchecked Sendable {
    func testTabBarIdentifierStats() throws {
        let credentials: SetupTestEnvironmentConfig.Credentials = .random()
        let iterations = 10
        let ids = RootLevelTab.allCases.map { "MHC:Tab:\($0.rawValue)" }
        let labels = RootLevelTab.allCases.map(\.rawValue)
        var idHits = 0
        var labelOnlyHits = 0
        var misses = 0
        var dumpsPrinted = 0
        for iteration in 0..<iterations {
            try launchAppAndEnrollIntoStudy(
                testEnvironmentConfig: .init(resetExistingData: iteration == 0, loginAndEnroll: .enable(credentials)),
                handlePermissionPrompts: iteration == 0 ? .yes : .no,
                skipGoingToHomeTab: true
            )
            // the first launch resets and re-seeds the test environment (Firebase login, study enrollment),
            // which can take a while; subsequent launches are fast
            XCTAssert(app.tabBars.element.waitForExistence(timeout: iteration == 0 ? 60 : 15))
            let allIdsPresent: Bool
            if app.tabBars.buttons[ids[0]].waitForExistence(timeout: 3) {
                allIdsPresent = ids.dropFirst().allSatisfy { app.tabBars.buttons[$0].exists }
            } else {
                allIdsPresent = false
            }
            if allIdsPresent {
                idHits += 1
            } else if labels.allSatisfy({ app.tabBars.buttons[$0].exists }) {
                labelOnlyHits += 1
                if dumpsPrinted < 2 {
                    dumpsPrinted += 1
                    print("AXSTATS[MHC] MISS DUMP iter \(iteration):")
                    print(app.tabBars.element.debugDescription)
                }
            } else {
                misses += 1
            }
            app.terminate()
        }
        print("AXSTATS[MHC] iterations=\(iterations) idHits=\(idHits) labelOnlyHits=\(labelOnlyHits) misses=\(misses)")
    }
}
