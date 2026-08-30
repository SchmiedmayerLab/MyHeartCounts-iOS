//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

private import GroveFoundation


public struct SetupTestEnvironmentConfig: Hashable, Sendable {
    public struct Credentials: Hashable, Sendable {
        public let username: String
        public let password: String
        
        public init(username: String, password: String) {
            self.username = username.lowercased() // normalize for firebase
            self.password = password
        }
    }
    
    public enum LoginAndEnrollOption: Hashable, Sendable {
        case skip
        case enable(Credentials)
    }
    
    public static let disabled = Self(resetExistingData: false, loginAndEnroll: .skip)
    
    /// Whether the app should reset all data on launch.
    ///
    /// This option will:
    /// - log out the current user
    /// - unenroll from the study
    /// - delete all cached study bundles
    /// - delete all pending uploads
    /// - reset the bulk health upload state
    /// - reset the SensorKit anchors
    /// - delete the entire `LocalStorage`
    public let resetExistingData: Bool
    
    /// Whether the app should log in to a test user.
    ///
    /// Specifying only this option but not also the previous one will simply ensure that the app has a logged-in user which is enrolled into the study.
    /// You can combine this option with the previous one to also ensure that the app is in a clean state.
    ///
    /// - Note: Setting this value to `false` does not mean that an existing user will be logged out.
    public let loginAndEnroll: LoginAndEnrollOption
    
    public init(resetExistingData: Bool, loginAndEnroll: LoginAndEnrollOption) {
        self.resetExistingData = resetExistingData
        self.loginAndEnroll = loginAndEnroll
    }
}


extension SetupTestEnvironmentConfig: LaunchOptionDecodable, LaunchOptionEncodable {
    public static let cliFlagName = "--setupTestEnvironment"
    public static let resetOptionName = "reset"
    public static let loginAndEnrollOptionName = "login-and-enroll"
    
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        try context.assertNumRawArgs(.atMost(2))
        let allowedOptions: Set = [Self.resetOptionName, Self.loginAndEnrollOptionName]
        if case let invalidOptions = context.rawArgs.filter({ $0 != Self.resetOptionName && !$0.starts(with: Self.loginAndEnrollOptionName) }),
           !invalidOptions.isEmpty {
            throw LaunchOptionDecodingError.other("Invalid input: \(invalidOptions). Expected \(allowedOptions)")
        }
        self.init(
            resetExistingData: context.rawArgs.contains(Self.resetOptionName),
            loginAndEnroll: try { () -> LoginAndEnrollOption in
                guard let arg = context.rawArgs.first(where: { $0.starts(with: Self.loginAndEnrollOptionName) }) else {
                    return .skip
                }
                guard let colonIdx = arg.firstIndex(of: ":") else {
                    // the option is present, but no credentials are supplied.
                    return .enable(.default)
                }
                let emailAndPassword = arg[colonIdx...].dropFirst()
                if emailAndPassword == "random" {
                    return .enable(.random())
                }
                guard let sepIdx = emailAndPassword.firstIndex(of: ";") else {
                    throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: arg)
                }
                let email = emailAndPassword[..<sepIdx]
                let password = emailAndPassword[sepIdx...].dropFirst()
                return .enable(Credentials(
                    username: String(email),
                    password: String(password)
                ))
            }()
        )
    }
    
    public func launchOptionArgs(for launchOption: LaunchOption<Self>) -> [String] {
        guard self != .disabled else {
            return []
        }
        return Array {
            launchOption.key
            if resetExistingData {
                Self.resetOptionName
            }
            switch loginAndEnroll {
            case .skip:
                let _ = () // swiftlint:disable:this redundant_discardable_let
            case .enable(let credentials):
                "\(Self.loginAndEnrollOptionName):\(credentials.username);\(credentials.password)"
            }
        }
    }
}


extension SetupTestEnvironmentConfig.Credentials {
    /// MHC default credentials
    public static let `default` = Self(username: "leland@stanford.edu", password: "StanfordRocks!")
    
    /// Creates new, random `Credentials`
    public static func random() -> Self {
        Self(
            username: "\(String.random(from: .alphanumerics, length: 12))@stanford.edu",
            password: .random(from: .printableASCII.excluding("' "), length: 12)
            // ^ we need to disallow `'`s to work around FB23653577
            //   we also disallow ` ` just to be safe
        )
    }
}


extension LaunchOptions {
    /// Configures a test environment in the app upon launch.
    ///
    /// - Note: When this option is specified and either of the two
    public static let setupTestEnvironment = LaunchOption<SetupTestEnvironmentConfig>(
        SetupTestEnvironmentConfig.cliFlagName,
        default: .init(resetExistingData: false, loginAndEnroll: .skip)
    )
}

#endif
