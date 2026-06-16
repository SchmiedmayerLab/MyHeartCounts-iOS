//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import Observation
import SpeziAccount


extension AccountDetails {
    /// Creates a `String` intended for debugging, describing the changes that exist between some other value and these `AccountDetails`.
    func debugDescOfDifference(from other: AccountDetails) -> String {
        // we perform a JSON roundtrip in order to turn the AccountDetails into a `JSONObject` (ie a `[String: JSONValue]`) which we then run the diff on.
        do {
            var result: [String] = []
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let jsonOld = try decoder.decode(JSONObject.self, from: try encoder.encode(other))
            let jsonNew = try decoder.decode(JSONObject.self, from: try encoder.encode(self))
            let diff = jsonNew.difference(from: jsonOld)
            for entry in diff.removed {
                result.append("- \(entry)")
            }
            for entry in diff.insertd {
                result.append("+ \(entry)")
            }
            for mutated in diff.mutated {
                result.append("~ \(mutated)")
            }
            return result.joined(separator: "\n")
        } catch {
            return ""
        }
    }
}


extension Dictionary where Value: Equatable {
    struct DictDifference {
        var removed: [(Key, Value)] = []
        var insertd: [(Key, Value)] = []
        var mutated: [(key: Key, old: Value, new: Value)] = [] // swiftlint:disable:this large_tuple
    }
    
    func difference(from prev: Self) -> DictDifference {
        var diff = DictDifference()
        diff.removed = prev.filter { self[$0.key] == nil }
        diff.insertd = self.filter { prev[$0.key] == nil }
        diff.mutated = self.compactMap { key, value in
            if let old = prev[key], old != value {
                (key, old, value)
            } else {
                nil
            }
        }
        return diff
    }
}
