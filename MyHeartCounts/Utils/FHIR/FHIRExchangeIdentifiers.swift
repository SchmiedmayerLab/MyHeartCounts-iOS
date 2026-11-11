//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4


enum FHIRExchangeIdentifiers {
    enum SourceRepository: String, Sendable {
        case healthKit = "healthkit"
        case questionnaire = "questionnaire"
        case sensorKit = "sensorkit"
    }

    /// The deployment root the Grove opaque, snapshot, record-version and record-retraction systems derive from.
    static let deploymentRoot: IdentifierSystem = "https://myheartcounts.stanford.edu/fhir"

    static let application: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/application"
    static let participant: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/participant"
    static let researchStudy: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/research-study"
    static let researchSubject: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/research-subject"
    static let repository: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/repository"
    static let healthKitNativeRecord: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/healthkit-record"
    static let sensorKitSourceRecord: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/sensorkit-record"
    static let visitLocation: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/sensorkit-visit-location"

    /// What every key id starts with, before the key's per-subject fingerprint.
    static let identityKeyIDPrefix = "s"

    /// The native SensorKit record system of the repository `scope` names, as
    /// ``FHIRExchangeStateStore/sensorKitRecordScope(of:secret:)`` gives it.
    static func sensorKitSourceRecord(scope: String) throws -> IdentifierSystem {
        try IdentifierSystem("\(sensorKitSourceRecord.rawValue)/\(scope)")
    }

    /// The canonical of the protocol one study revision follows.
    static func studyProtocol(studyID: String) -> FHIRPrimitive<Canonical> {
        FHIRPrimitive(Canonical(stringLiteral: "\(deploymentRoot.rawValue)/PlanDefinition/\(studyID)"))
    }
}
