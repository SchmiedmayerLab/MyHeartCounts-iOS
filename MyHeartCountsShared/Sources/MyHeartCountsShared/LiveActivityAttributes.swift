//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)

public import ActivityKit
public import Foundation
public import GroveStudyDefinition


public struct TimedWalkTestLiveActivityAttributes: ActivityAttributes {
    public enum ContentState: Hashable, Codable, Sendable {
        case ongoing(startDate: Date, endDate: Date)
        case completed(numSteps: Int, distance: Measurement<UnitLength>)
    }
    
    /// The id of the specific test run.
    public let testRunId: UUID
    
    // periphery:ignore - API
    /// The test being conducted
    public let test: TimedWalkingTestConfiguration
    
    @inlinable
    public init(testRunId: UUID, test: TimedWalkingTestConfiguration) {
        self.testRunId = testRunId
        self.test = test
    }
}

#endif
