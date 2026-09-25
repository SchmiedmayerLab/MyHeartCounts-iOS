//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import MyHeartCountsShared
import SFSafeSymbols


extension WorkoutPreferenceSetting {
    struct WorkoutType: Hashable, Identifiable, Sendable {
        let id: String
        let title: LocalizedStringResource
        let symbol: SFSymbol
    }
    
    
    struct NotificationTime: Hashable, LosslessStringConvertible, Codable, Sendable {
        var hour: Int
        var minute: Int
        
        var description: String {
            String(format: "%.02ld:%02ld", hour, minute)
        }
        
        init(hour: Int, minute: Int = 0) {
            self.hour = hour.clamped(to: 0...23)
            self.minute = minute.clamped(to: 0...59)
        }
        
        init?(_ description: String) {
            let components = description.split(separator: ":")
            guard components.count == 2,
                  let hour = Int(components[0]),
                  let minute = Int(components[1]),
                  (0..<24).contains(hour),
                  (0..<60).contains(minute) else {
                return nil
            }
            self.init(hour: hour, minute: minute)
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let description = try container.decode(String.self)
            if let time = Self(description) {
                self = time
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unable to parse '\(description)' into a \(Self.self)"))
            }
        }
        
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }
    }
}


extension WorkoutPreferenceSetting.WorkoutType {
    static let options: [Self] = [
        Self(id: "walk", title: "Walking", symbol: .figureWalk),
        Self(id: "run", title: "Running", symbol: .figureRun),
        Self(id: "bicycle", title: "Cycling", symbol: .figureOutdoorCycle),
        Self(id: "swim", title: "Swimming", symbol: .figurePoolSwim),
        Self(id: "strength", title: "Strength", symbol: .figureStrengthtrainingFunctional),
        Self(id: "HIIT", title: "High-intensity Training", symbol: .figureHighintensityIntervaltraining),
        Self(id: "yoga/pilates", title: "Yoga / Pilates", symbol: .figureYoga),
        Self(id: "sport", title: "Sport", symbol: .figureIndoorSoccer),
        Self(id: "other", title: "Other", symbol: .figureDance)
    ]
    
    init?(id: ID) {
        if let value = Self.options.first(where: { $0.id == id }) {
            self = value
        } else {
            return nil
        }
    }
}


extension WorkoutPreferenceSetting {
    struct WorkoutTypes: Hashable, Sendable {
        private var elements: Set<WorkoutType>
        
        init() {
            elements = Set()
        }
        
        init(_ options: some Sequence<WorkoutType>) {
            elements = Set(options)
        }
        
        mutating func insert(_ element: WorkoutType) {
            elements.insert(element)
        }
        
        mutating func remove(_ element: WorkoutType) {
            elements.remove(element)
        }
    }
}


extension WorkoutPreferenceSetting.WorkoutTypes: Collection {
    typealias Element = Set<WorkoutPreferenceSetting.WorkoutType>.Element
    typealias Index = Set<WorkoutPreferenceSetting.WorkoutType>.Index
    
    var startIndex: Index {
        elements.startIndex
    }
    
    var endIndex: Index {
        elements.endIndex
    }
    
    func index(after idx: Index) -> Index {
        elements.index(after: idx)
    }
    
    subscript(position: Index) -> Element {
        elements[position]
    }
}


extension WorkoutPreferenceSetting.WorkoutTypes: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        let elementIds = rawValue.split(separator: ",")
        self.elements = elementIds.compactMapIntoSet { Element(id: String($0)) }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements.map(\.id).joined(separator: ",")) // assumption: the ids never contain commas.
    }
}
