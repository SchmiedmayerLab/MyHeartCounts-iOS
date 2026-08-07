//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4


struct SpeziCodingSystem: CodingProtocol {
    static let system: FHIRPrimitive<FHIRURI> = "https://spezi.stanford.edu"
    
    let code: FHIRPrimitive<FHIRString>
    let display: FHIRPrimitive<FHIRString>?
    
    init(_ code: FHIRPrimitive<FHIRString>, display: FHIRPrimitive<FHIRString>? = nil) {
        self.code = code
        self.display = display
    }
}


extension SpeziCodingSystem {
    static let watchWristLocation = Self("watchWristLocation")
    static let watchCrownOrientation = Self("watchCrownOrientation")
}
