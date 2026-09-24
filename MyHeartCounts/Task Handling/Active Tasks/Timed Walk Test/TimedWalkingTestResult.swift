//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order
// periphery:ignore:all

import CoreMotion
import Foundation
import GroveStudyDefinition


struct TimedWalkingTestResult: Hashable, Codable, Sendable {
    let id: UUID
    let test: TimedWalkingTestConfiguration
    let startDate: Date
    let endDate: Date
    var numberOfSteps: Int
    /// The distance covered, in meters.
    var distanceCovered: Double
}


struct AbsoluteAltitudeMeasurement: Hashable, Codable, Sendable {
    let timestamp: TimeInterval
    let altitude: Double
    let accuracy: Double
    let precision: Double
    
    init(_ data: CMAbsoluteAltitudeData) {
        self.timestamp = data.timestamp
        self.altitude = data.altitude
        self.accuracy = data.accuracy
        self.precision = data.precision
    }
}


struct RelativeAltitudeMeasurement: Hashable, Codable, Sendable {
    let timestamp: TimeInterval
    /// The change in altitude (in meters) since the first reported event.
    let altitude: Double
    /// Recorded pressure, in kPa
    let pressure: Double
    
    init(_ data: CMAltitudeData) {
        self.timestamp = data.timestamp
        self.altitude = data.relativeAltitude.doubleValue
        self.pressure = data.pressure.doubleValue
    }
}


struct PedometerData: Hashable, Codable, Sendable {
    let startDate: Date
    let endDate: Date
    let numberOfSteps: Int
    let distance: Double?
    let floorsAscended: Int?
    let floorsDescended: Int?
    let currentPace: Double?
    let currentCadence: Double?
    let averageActivePace: Double?
    
    init(_ data: CMPedometerData) {
        self.startDate = data.startDate
        self.endDate = data.endDate
        self.numberOfSteps = data.numberOfSteps.intValue
        self.distance = data.distance?.doubleValue
        self.floorsAscended = data.floorsAscended?.intValue
        self.floorsDescended = data.floorsDescended?.intValue
        self.currentPace = data.currentPace?.doubleValue
        self.currentCadence = data.currentCadence?.doubleValue
        self.averageActivePace = data.averageActivePace?.doubleValue
    }
}


struct PedometerEvent: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case date
        case type
    }
    
    let date: Date
    let type: CMPedometerEventType
    
    init(_ event: CMPedometerEvent) {
        self.date = event.date
        self.type = event.type
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(Date.self, forKey: .date)
        guard let type = CMPedometerEventType(rawValue: try container.decode(CMPedometerEventType.RawValue.self, forKey: .type)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Invalid raw value"))
        }
        self.type = type
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(type.rawValue, forKey: .type)
    }
}
