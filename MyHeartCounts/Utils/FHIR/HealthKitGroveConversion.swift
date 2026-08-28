//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ModelsR4


extension FirebaseConfiguration {
    /// The participant every converted resource is about.
    @MainActor var subjectReference: Reference {
        get throws(ConfigurationError) {
            Reference(reference: "Patient/\(try accountId)".asFHIRStringPrimitive())
        }
    }
}


extension HealthKitConversionContext {
    /// The namespace the deployment owns for the graph nodes an export mints.
    static let graphIdentifierSystem: IdentifierSystem = "https://myheartcounts.stanford.edu/fhir/healthkit/graph"

    /// The conversion context for the enrolled participant.
    static func mhc(subject: Reference, conversionInstant: Date = .now) -> Self {
        Self(
            subject: subject,
            graphIdentifierSystem: graphIdentifierSystem,
            conversionInstant: conversionInstant,
            sourceRevisionDisclosurePolicy: .authorized,
            researchStudies: MyHeartCountsStandard.currentEnrollmentInfo.map {
                [Reference(reference: "ResearchStudy/\($0.studyId)".asFHIRStringPrimitive())]
            } ?? []
        )
    }
}
