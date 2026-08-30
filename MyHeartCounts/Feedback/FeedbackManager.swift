//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - some of the properties in the `Feedback` struct are set-only from the app's POV.

@preconcurrency import FirebaseFirestore
import Foundation
import Grove
import GroveAccount
import GroveFirestore
import OSLog
import class UIKit.UIDevice


@MainActor
final class FeedbackManager: Module, EnvironmentAccessible, @unchecked Sendable {
    // swiftlint:disable attributes
    @Application(\.logger) private var logger
    @Dependency(Account.self) private var account: Account?
    @Dependency(FirebaseConfiguration.self) private var firebaseConfiguration: FirebaseConfiguration?
    // swiftlint:enable attributes
    
    func submit(message: String) async throws {
        guard let accountId = account?.details?.accountId, let feedbackCollection = firebaseConfiguration?.feedbackCollection else {
            logger.error("Asked to submit feedback but no account found.")
            return
        }
        let feedback = Feedback(accountId: accountId, message: message)
        let doc = feedbackCollection.document(UUID().uuidString)
        try await doc.setData(from: feedback)
    }
}


extension FeedbackManager {
    private struct Feedback: Encodable {
        struct DeviceInfo: Encodable {
            let osVersion: String
            let model: String
            let type: String
            
            @MainActor
            init() {
                let device = UIDevice.current
                osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                model = device.model
                var systemInfo = utsname()
                uname(&systemInfo)
                type = withUnsafePointer(to: &systemInfo.machine) {
                    $0.withMemoryRebound(to: CChar.self, capacity: numericCast(_SYS_NAMELEN)) {
                        String(validatingCString: $0)
                    }
                } ?? ""
            }
        }
        
        
        /// The version of the `FeedbackItem` data structure.
        /// Used to enable backward compatibility in case of potential future changes here.
        let version: Int
        let accountId: String
        let message: String
        let date: Date
        let timeZone: String
        let appVersion: String
        let appBuildNumber: Int
        let deviceInfo: DeviceInfo
        
        @MainActor
        init(accountId: String, message: String) {
            self.version = 1
            self.accountId = accountId
            self.message = message
            self.date = .now
            self.timeZone = TimeZone.current.identifier
            self.appVersion = Bundle.main.appVersion
            self.appBuildNumber = Bundle.main.appBuildNumber ?? -1
            self.deviceInfo = DeviceInfo()
        }
    }
}
