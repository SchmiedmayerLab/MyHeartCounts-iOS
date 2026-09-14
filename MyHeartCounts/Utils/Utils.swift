//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SFSafeSymbols
import SpeziViews


extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
    var appBuildNumber: Int? {
        (infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
    }
}


extension ImageReference {
    static func system(_ symbol: SFSymbol) -> Self {
        .system(symbol.rawValue)
    }
}


extension Result {
    var value: Success? {
        switch self {
        case .success(let value):
            value
        case .failure:
            nil
        }
    }
}


extension Range where Bound == Date {
    var timeInterval: TimeInterval {
        upperBound.timeIntervalSince(lowerBound)
    }
}
