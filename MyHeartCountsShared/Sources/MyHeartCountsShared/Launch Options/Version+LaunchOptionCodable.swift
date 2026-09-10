//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)
public import SpeziFoundation


extension Version: LaunchOptionDecodable, LaunchOptionEncodable {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        try context.assertNumRawArgs(.equal(1))
        let raw = context.rawArgs[0]
        if let version = Version(raw) {
            self = version
        } else {
            throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: raw)
        }
    }
    
    public func launchOptionArgs(for launchOption: LaunchOption<Version>) -> [String] {
        [launchOption.key, self.description]
    }
}
#endif
