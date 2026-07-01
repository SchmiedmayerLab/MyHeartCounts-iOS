//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//


public struct PromptedActionID: Hashable, Codable, CustomStringConvertible, Sendable {
    /// The pattern all `PromptedAction` IDs must match. Simple reverse DNS notation.
    ///
    /// We enforce this in order to be able to express a list of IDs as a comma-separated list without needing to worry about a comma potentially being part of an ID.
    nonisolated(unsafe) private static let pattern = /^[A-Za-z0-9]+(\.[A-Za-z0-9]+)*$/
    
    package let value: String
    
    public var description: String {
        value
    }
    
    public init<S: StringProtocol>(_ value: S) where S.SubSequence == Substring {
        precondition(
            value.wholeMatch(of: Self.pattern) != nil,
            "PromptedAction.ID must match \(Self.pattern._literalPattern ?? "simple reverse DNS notation"). Input value: '\(value)'"
        )
        self.value = String(value)
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}

extension PromptedActionID {
    public static let sensorKit = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableSensorKit")
    public static let clinicalRecords = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableClinicalRecords")
    public static let verifyAccountEmail = Self("edu.stanford.MyHeartCounts.HomeTabAction.verifyAccountEmail")
    public static let completeDemographics = Self("edu.stanford.MyHeartCounts.HomeTabAction.completeDemographics")
}
