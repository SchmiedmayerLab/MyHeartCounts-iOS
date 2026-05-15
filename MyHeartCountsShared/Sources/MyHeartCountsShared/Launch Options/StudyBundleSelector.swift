//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

public import struct Foundation.URL


public enum StudyBundleSelector: Hashable, LaunchOptionDecodable {
    /// The default study bundle, as available in firebase
    case firebase
    /// A study bundle dynamically produced by version of `MyHeartCounts-StudyDefinitions` the app was compiled against
    case bundledWithApp
    /// The study bundle located at the specified URL.
    case atUrl(URL)
    
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        try context.assertNumRawArgs(.equal(1))
        switch context.rawArgs[0] {
        case "firebase":
            self = .firebase
        case "bundledWithApp":
            self = .bundledWithApp
        default:
            self = .atUrl(try URL(decodingLaunchOption: context))
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
    public static let studyBundleSelector = LaunchOption<StudyBundleSelector>("--studyBundle", default: .firebase)
}

#endif
