//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order attributes discouraged_optional_boolean

import Foundation
import Grove
import GroveAccount
import GroveFoundation
import MyHeartCountsShared
import SwiftUI


@Observable
@MainActor
final class AccountFeatureFlags: Module, EnvironmentAccessible, Sendable {
    struct FeatureFlagDefinition: Sendable {
        enum Source: Sendable {
            case accountDetail(any KeyPath<AccountDetails, Bool?> & Sendable)
            case localPreference(LocalPreferenceKey<Bool>)
            case launchOption(LaunchOption<Bool>)
        }
        let sources: [Source]
    }
    
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    
    nonisolated init() {}
    
    subscript(flag: FeatureFlagDefinition) -> Bool {
        flag.sources.contains { source in
            switch source {
            case .accountDetail(let keyPath):
                account?.details?[keyPath: keyPath] == true
            case .localPreference(let key):
                LocalPreferencesStore.standard[key] == true
            case .launchOption(let option):
                LaunchOptions[option]
            }
        }
    }
}


extension AccountFeatureFlags.FeatureFlagDefinition {
    static let isDebugModeEnabled = Self(sources: [
        .accountDetail(\.enableDebugMode),
        .launchOption(.forceEnableDebugMode),
        .localPreference(.lastSeenIsDebugModeEnabledAccountKey)
    ])
}


@MainActor
@propertyWrapper
struct AccountFeatureFlagQuery: DynamicProperty {
    @Environment(AccountFeatureFlags.self)
    private var featureFlags
    
    private let flag: AccountFeatureFlags.FeatureFlagDefinition
    
    var wrappedValue: Bool {
        featureFlags[flag]
    }
    
    // periphery:ignore - implicitly called
    init(_ flag: AccountFeatureFlags.FeatureFlagDefinition) {
        self.flag = flag
    }
}
