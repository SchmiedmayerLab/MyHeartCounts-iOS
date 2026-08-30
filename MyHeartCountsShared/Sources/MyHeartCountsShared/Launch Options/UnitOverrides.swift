//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

import Foundation
import GroveFoundation


/// Common interface & operations for launch options that allow specifying a unit that should be used for something.
public protocol _UnitOverrideLaunchOption: LaunchOptionDecodable, LaunchOptionEncodable, RawRepresentable, CaseIterable where RawValue == String {
    // swiftlint:disable:previous type_name
    static var none: Self { get }
}

extension _UnitOverrideLaunchOption {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws { // swiftlint:disable:this missing_docs
        try context.assertNumRawArgs(.atMost(1))
        switch context.rawArgs[safe: 0] {
        case nil, "none":
            self = .none
        case .some(let arg):
            if let selfValue = Self.allCases.first(where: { $0.rawValue == arg }) {
                self = selfValue
            } else {
                throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: arg)
            }
        }
    }
    
    public func launchOptionArgs(for launchOption: LaunchOption<Self>) -> [String] { // swiftlint:disable:this missing_docs
        if self == .none {
            []
        } else {
            [launchOption.key, self.rawValue]
        }
    }
}


extension LaunchOptions {
    /// Height unit override options.
    public enum HeightInputUnitOverride: String, _UnitOverrideLaunchOption {
        case none
        case cm // swiftlint:disable:this identifier_name
        case feet
    }
    
    /// Allows overriding which unit should be used when entering a height value into the app.
    public static let heightInputUnitOverride = LaunchOption<HeightInputUnitOverride>("--heightInputUnitOverride", default: .none)
}


extension LaunchOptions {
    /// Weight unit override options.
    public enum WeightInputUnitOverride: String, _UnitOverrideLaunchOption {
        case none
        case kg // swiftlint:disable:this identifier_name
        case lbs
    }
    
    /// Allows overriding which unit should be used when entering a weight value into the app.
    public static let weightInputUnitOverride = LaunchOption<WeightInputUnitOverride>("--weightInputUnitOverride", default: .none)
}

#endif
