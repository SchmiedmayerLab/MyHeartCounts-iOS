//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if canImport(SwiftUI)

import Algorithms
import Foundation
import GroveFoundation
public import SwiftUI


func lerp<T: FloatingPoint>(from a: T, to b: T, t: T) -> T { // swiftlint:disable:this identifier_name
    a + (b - a) * t
}

extension Gradient {
    /// Calculates the color at a specific position within the gradient.
    public func color(at position: CGFloat) -> Color {
        guard !stops.isEmpty else {
            preconditionFailure("Empty gradient!")
        }
        assert(stops.isSorted(by: { $0.location < $1.location }))
        
        let position = position.clamped(to: 0...1)
        
        guard stops.count > 1 else {
            return stops[0].color
        }
        
        if let stop = stops.first, position <= stop.location {
            return stop.color
        } else if let stop = stops.last, position >= stop.location {
            return stop.color
        }
        
        let surroundingStops = stops.adjacentPairs().first { lhs, rhs in
            (lhs.location...rhs.location).contains(position)
        }
        guard let (stop1, stop2) = surroundingStops else {
            fatalError("unreachable")
        }

        let segmentLength = stop2.location - stop1.location
        if segmentLength <= 0 {
            return stop1.color
        }
        
        let rgba1 = stop1.color.resolve(in: .init())
        let rgba2 = stop2.color.resolve(in: .init())
        
        let t = (position - stop1.location) / segmentLength // swiftlint:disable:this identifier_name
        let red = lerp(from: Double(rgba1.red), to: Double(rgba2.red), t: t)
        let green = lerp(from: Double(rgba1.green), to: Double(rgba2.green), t: t)
        let blue = lerp(from: Double(rgba1.blue), to: Double(rgba2.blue), t: t)
        let alpha = lerp(from: Double(rgba1.opacity), to: Double(rgba2.opacity), t: t)
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}


extension Comparable {
    /// Clamps the value to the range.
    @inlinable
    public func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(range.upperBound, self))
    }
}

#endif
