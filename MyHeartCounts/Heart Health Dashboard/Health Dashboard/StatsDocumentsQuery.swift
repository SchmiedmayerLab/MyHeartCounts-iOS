//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SpeziAccount
import SpeziHealthKit
import SpeziHealthKitUI
import SwiftUI


/// SwiftUI adapter for ``StatsStore``. Non-UI consumers use the same ``StatsStore.Request`` with the store directly.
@MainActor
@propertyWrapper
struct StatsDocumentsQuery<Element: Sendable>: DynamicProperty {
    @Environment(Account.self)
    private var account: Account?
    @Environment(StatsStore.self)
    private var store: StatsStore?
    @State private var observation = StatsStore.Subscription<Element>()
    private let request: StatsStore.Request<Element>

    var wrappedValue: [Element] {
        // Observe account/session changes even when the query itself remains unchanged.
        _ = account?.details?.accountId
        _ = store?.sessionRevision
        return observation.elements
    }

    /// Initial loading, updates to retained data, errors, cache metadata, and source-selection diagnostics.
    var projectedValue: StatsStore.Subscription<Element> {
        _ = account?.details?.accountId
        _ = store?.sessionRevision
        return observation
    }

    init(_ request: StatsStore.Request<Element>) {
        self.request = request
    }

    nonisolated func update() {
        MainActor.assumeIsolated {
            guard let store else {
                observation.fail(StatsStore.Error.unavailable, clear: true)
                return
            }
            guard account?.details?.accountId != nil else {
                observation.fail(StatsStore.Error.notSignedIn, clear: true)
                return
            }
            observation.update(request: request, store: store)
        }
    }
}


extension StatsDocumentsQuery where Element == QuantitySample {
    init(
        metric: HealthStatsMetric,
        timeRange: HealthKitQueryTimeRange,
        aggregationKind: StatisticsAggregationOption,
        sourcePolicy: StatsStore.SourcePolicy = .automatic,
        interval: StatsStore.AggregationInterval? = nil
    ) {
        self.init(.quantity(
            metric: metric,
            timeRange: timeRange,
            aggregationKind: aggregationKind,
            sourcePolicy: sourcePolicy,
            interval: interval
        ))
    }
}


extension StatsDocumentsQuery where Element == SleepSessionStatsSample {
    init(sleepSessionsIn timeRange: HealthKitQueryTimeRange, sourcePolicy: StatsStore.SourcePolicy = .automatic) {
        self.init(.sleepSessions(in: timeRange, sourcePolicy: sourcePolicy))
    }
}


extension StatsDocumentsQuery where Element == BloodPressureStatsSample {
    init(bloodPressureIn timeRange: HealthKitQueryTimeRange, sourcePolicy: StatsStore.SourcePolicy = .automatic) {
        self.init(.bloodPressure(in: timeRange, sourcePolicy: sourcePolicy))
    }
}
