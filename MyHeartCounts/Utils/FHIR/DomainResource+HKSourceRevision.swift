//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveFHIR
import GroveHealthKitFHIR
import HealthKit
import ModelsDSTU2
import ModelsR4


extension HKSourceRevision {
    static let mhc = HKSourceRevision(
        source: HKSource.default(),
        version: "\(Bundle.main.appVersion) (\(Bundle.main.appBuildNumber ?? -1))",
        productType: nil,
        operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
    )
}


extension ModelsDSTU2.DomainResource {
    // periphery:ignore - API
    mutating func addMHCAppAsSource() {
        addSourceRevisionExtensions(for: .mhc)
    }
}

extension ModelsR4.DomainResource {
    mutating func addMHCAppAsSource() {
        addSourceRevisionExtensions(for: .mhc)
    }
}
