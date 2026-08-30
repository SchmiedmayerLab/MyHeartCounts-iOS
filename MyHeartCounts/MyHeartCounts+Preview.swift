//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveAccount
import GroveStudy


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
