//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API

#if canImport(HealthKit)

private import GroveFoundation
public import class HealthKit.HKUnit


public protocol _HKUnitCodableExtensionProtocol: Codable { // swiftlint:disable:this type_name
    /// String representation of the `HKUnit`
    var unitString: String { get }
    /// Attempts to create a `HKUnit` from a string.
    static func parse(_ unitString: String) -> HKUnit?
}

extension _HKUnitCodableExtensionProtocol {
    public init(from decoder: any Decoder) throws { // swiftlint:disable:this missing_docs
        let container = try decoder.singleValueContainer()
        let unitString = try container.decode(String.self)
        guard let unit = Self.parse(unitString) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Invalid unit string '\(unitString)'"
            ))
        }
        guard let unit = unit as? Self else {
            preconditionFailure(
                """
                Unexpectedly got \(type(of: unit)) result instead of \(Self.self).
                This should not happen as only HKUnit is allowed to conform to the \((any _HKUnitCodableExtensionProtocol).self) protocol.
                """
            )
        }
        self = unit
    }
    
    public func encode(to encoder: any Encoder) throws { // swiftlint:disable:this missing_docs
        var container = encoder.singleValueContainer()
        try container.encode(unitString)
    }
}


extension HKUnit: _HKUnitCodableExtensionProtocol, @retroactive Codable {
    public static func parse(_ unitString: String) -> HKUnit? {
        // ideally this would be a failing convenience init, but the language isn't able to express that.
        // (we could define it as a category in ObjC, but this is good enough...)
        try? catchingNSException {
            HKUnit(from: unitString)
        }
    }
}


#endif
