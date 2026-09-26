//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

public import struct Foundation.URL
public import MHCStudyDefinition


public enum StudyBundleSelector: Hashable {
    /// The default study bundle, as available in firebase
    case firebase(StudyVariant)
    /// A study bundle dynamically produced by version of `MyHeartCounts-StudyDefinitions` the app was compiled against
    case bundledWithApp(StudyVariant)
    /// The study bundle located at the specified URL.
    case atUrl(URL)
    
    /// Returns a new selector, that fetches a study bundle from the same source but using the specified variant.
    ///
    /// - Note: If the selector doesn't carry any variant information, it will be returned as-is.
    public func withVariant(_ variant: StudyVariant?) -> Self {
        guard let variant else {
            return self
        }
        return switch self {
        case .firebase:
            .firebase(variant)
        case .bundledWithApp:
            .bundledWithApp(variant)
        case .atUrl:
            self
        }
    }
}


extension StudyBundleSelector: LaunchOptionDecodable, LaunchOptionEncodable {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        try context.assertNumRawArgs(.equal(1))
        if let (source, variant) = try Self.parseSourceAndVariant(context.rawArgs[0]) {
            let variant = variant ?? .stanford // if the variant is omitted we default it to stanford
            switch source {
            case "firebase":
                self = .firebase(variant)
            case "bundledWithApp":
                self = .bundledWithApp(variant)
            default:
                throw LaunchOptionDecodingError.other("Invalid study bundle source '\(source)'")
            }
        } else {
            self = .atUrl(try URL(decodingLaunchOption: context))
        }
    }
    
    private static func parseSourceAndVariant(_ input: String) throws -> (String, StudyVariant?)? {
        let source = String(input.prefix { $0 != ":" })
        guard source == "firebase" || source == "bundledWithApp" else {
            return nil
        }
        guard let colonIdx = input.firstIndex(of: ":") else {
            // no colon
            // important that we only return nil for the variant if it was omitted, and not if it failed to parse
            return (input, nil)
        }
        let variantPart = input[colonIdx...].dropFirst()
        guard let variant = StudyVariant(rawValue: String(variantPart)) else {
            throw LaunchOptionDecodingError.unableToDecode(StudyVariant.self, rawValue: String(variantPart))
        }
        return (source, variant)
    }
    
    public func launchOptionArgs(for launchOption: LaunchOption<StudyBundleSelector>) -> [String] {
        switch self {
        case .firebase(let variant):
            [launchOption.key, "firebase:\(variant.rawValue)"]
        case .bundledWithApp(let variant):
            [launchOption.key, "bundledWithApp:\(variant.rawValue)"]
        case .atUrl(let url):
            url.launchOptionArgs(for: LaunchOption<URL>(launchOption.key, default: url))
        }
    }
}


extension LaunchOptions {
    /// Controls from where the app obtains its study bundle.
    ///
    /// Allowed values are:
    /// - `firebase`
    /// - `bundledWithApp`
    /// - a `URL`, which can be either a web url (https) or a local file system url.
    ///
    /// See ``StudyBundleSelector`` for more information.
    public static let studyBundleSelector = LaunchOption<StudyBundleSelector>("--studyBundle", default: .bundledWithApp(.stanford))
}

#endif
