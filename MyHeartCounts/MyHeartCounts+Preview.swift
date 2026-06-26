//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Spezi
import SpeziAccount
import SpeziStudy


extension MyHeartCounts {
    @MainActor @ModuleBuilder static var previewModels: ModuleCollection {
        DeferredConfigLoading.baseModules(preferredLocale: .autoupdatingCurrent)
        FirebaseConfiguration()
        AccountConfiguration(service: InMemoryAccountService(), configuration: .default)
        StudyBundleLoader.shared
        AccountFeatureFlags()
        SetupTestEnvironment()
    }
}
