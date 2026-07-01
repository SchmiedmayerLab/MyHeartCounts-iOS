//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

public enum PromptedActionsFilter: LaunchOptionDecodable, LaunchOptionEncodable, Sendable {
    /// No filter should be applied
    case none
    case only(Set<PromptedActionID>)
    case except(Set<PromptedActionID>)
    
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        try context.assertNumRawArgs(.equal(1))
        let rawArg = context.rawArgs[0]
        let components = rawArg.split(separator: "=", omittingEmptySubsequences: false)
        guard components.count == 2 else {
            if rawArg == "none" {
                self = .none
                return
            }
            throw LaunchOptionDecodingError.other("Invalid format; expected '<specifier>=<id1,id2,...>'; got '\(rawArg)'")
        }
        let specifier = components[0]
        let ids = components[1]
            .split(separator: ",")
            .mapIntoSet { PromptedActionID($0) }
        switch specifier {
        case "none" where ids.isEmpty:
            self = .none
        case "only":
            self = .only(ids)
        case "except":
            self = .except(ids)
        default:
            throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: rawArg)
        }
    }
    
    public func launchOptionArgs(for launchOption: LaunchOption<Self>) -> [String] {
        let (specifier, ids): (String, Set<PromptedActionID>) = switch self {
        case .none:
            ("none", [])
        case .only(let ids):
            ("only", ids)
        case .except(let ids):
            ("except", ids)
        }
        return [launchOption.key, "\(specifier)=\(ids.map(\.value).joined(separator: ","))"]
    }
}


extension LaunchOptions {
    /// Comma-separated list of ``PromptedAction/ID``s. If speciified, the app will consider only these actions.
    public static let promptedActionsFilter = LaunchOption<PromptedActionsFilter>("--prompted-actions-filter", default: .none)
}

#endif
