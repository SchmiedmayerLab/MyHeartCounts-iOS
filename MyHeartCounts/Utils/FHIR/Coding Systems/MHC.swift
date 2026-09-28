//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import ModelsR4


/// My Heart Counts' own coding system, for codes that have no entry in a published vocabulary.
struct MHCCodingSystem: CodingProtocol {
    static let system: FHIRPrimitive<FHIRURI> = "https://myheartcounts.stanford.edu/fhir/CodeSystem/sampleType"

    /// The system this coding system was published under before the Grove migration.
    ///
    /// Never written; resources uploaded by earlier app versions carry it, so reads have to keep accepting it.
    static let supersededSystem: FHIRPrimitive<FHIRURI> = "https://spezi.stanford.edu"

    /// Every system uri a coding of this system might carry, canonical first.
    static let allSystems: [FHIRPrimitive<FHIRURI>] = [system, supersededSystem]

    let code: FHIRPrimitive<FHIRString>
    let display: FHIRPrimitive<FHIRString>?

    init(_ code: FHIRPrimitive<FHIRString>, display: FHIRPrimitive<FHIRString>? = nil) {
        self.code = code
        self.display = display
    }
}


extension MHCCodingSystem {
    static let watchWristLocation = Self("watchWristLocation")
    static let watchCrownOrientation = Self("watchCrownOrientation")
}
