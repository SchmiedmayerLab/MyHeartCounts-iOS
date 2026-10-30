//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import GroveStudyDefinition
import GroveViews
import ModelsR4
import MyHeartCountsShared
import SFSafeSymbols
import SwiftUI


struct PastTimedWalkTestResults: View {
    @MHCFirestoreQuery(fetching: TimedWalkingTestResult.self, timeRange: .ever)
    private var pastTests
    
    @PerformTask private var performTask
    
    var body: some View {
        Form {
            Section("New Test") {
                newTestSection
            }
            if !pastTests.isEmpty {
                Section("Past Tests") {
                    ForEach(pastTests, id: \.id) { (result: TimedWalkingTestResult) in
                        NavigationLink {
                            makeDetailsView(for: result)
                        } label: {
                            LabeledContent(result.test.displayTitle, value: result.startDate, format: .dateTime)
                        }
                    }
                }
            }
        }
        .navigationTitle("Timed Walking/Running Tests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DismissButton()
            }
        }
    }
    
    @ViewBuilder private var newTestSection: some View {
        let tests: [TimedWalkingTestConfiguration] = [
            .sixMinuteWalkTest,
            .twelveMinuteRunTest
        ]
        ForEach(tests, id: \.self) { test in
            Button {
                performTask(.timedWalkTest(test))
            } label: {
                Label {
                    Text(test.displayTitle)
                } icon: {
                    Image(systemSymbol: test.kind.symbol)
                        .accessibilityHidden(true)
                }
            }
        }
    }
    
    @ViewBuilder
    private func makeDetailsView(for result: TimedWalkingTestResult) -> some View {
        Form {
            TimedWalkRunTestResultInfo(result: result)
        }
        .navigationTitle(result.test.displayTitle.localizedString())
        .navigationBarTitleDisplayMode(.inline)
    }
}


extension MHCFirestoreQuery {
    private struct ResourceProxyToTWTResult: ValueTransformer {
        struct Failure: Error {}
        
        func transform(_ input: ResourceProxy) throws -> TimedWalkingTestResult {
            guard let observation = input.get(if: Observation.self),
                  let testResult = TimedWalkingTestResult(consume observation) else {
                throw Failure()
            }
            return testResult
        }
    }
    
    // periphery:ignore - we're using this init (the property wrapper in the view above...) but periphery doesn't seem to be able to see that use.
    init(
        fetching _: TimedWalkingTestResult.Type,
        timeRange: HealthKitQueryTimeRange,
        sorted sortComparator: some SortComparator<TimedWalkingTestResult> = KeyPathComparator(\.startDate, order: .reverse),
        limit: Int? = nil
    ) where Element == TimedWalkingTestResult {
        self.init(
            sampleTypeIdentifier: TimedWalkingTestResult.sampleTypeIdentifier,
            timeRange: timeRange,
            sorted: [sortComparator],
            limit: limit,
            transform: ResourceProxyToTWTResult()
        )
    }
}
