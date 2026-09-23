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

    /// The deployment root the Grove opaque, event, and entry-node systems derive from.
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

    /// The wire-visible key id selecting the store-bound secret every identity is minted from.
    static let identityKeyID = "store"

    /// The canonical of the protocol one study revision follows.
    static func studyProtocol(studyID: String) -> FHIRPrimitive<Canonical> {
        FHIRPrimitive(Canonical(stringLiteral: "\(deploymentRoot.rawValue)/PlanDefinition/\(studyID)"))
    }
}


extension FHIRExchangeEventFacts {
    var application: ApplicationDevice {
        get throws {
            try ApplicationDevice(
                name: applicationName,
                bundleIdentifier: applicationBundleIdentifier,
                version: applicationVersion,
                build: applicationBuild
            )
        }
    }

    var host: HostDevice {
        get throws {
            try HostDevice(
                operatingSystemVersion: hostOperatingSystemVersion,
                name: hostName,
                manufacturer: hostManufacturer,
                modelNumber: hostModelNumber
            )
        }
    }

    /// The enrollment the event is relevant to, stated with the exact protocol revision it ran under.
    func studies(for subject: FHIRExchangeSubject) throws -> [StudyEnrollment] {
        guard let study else {
            return []
        }
        return [
            try StudyEnrollment(
                study: BusinessIdentifier(system: FHIRExchangeIdentifiers.researchStudy, value: study.id),
                protocolURL: FHIRExchangeIdentifiers.studyProtocol(studyID: study.id),
                protocolVersion: String(study.revision),
                enrollment: BusinessIdentifier(
                    system: FHIRExchangeIdentifiers.researchSubject,
                    value: "\(study.id):\(subject.identity.value)"
                )
            )
        ]
    }
}


extension FHIRExchangeStateStore {
    /// The complete shared context of one persisted event, rebuilt identically on every retry.
    func eventContext(
        for event: PersistedFHIRExchangeEvent,
        subject: FHIRExchangeSubject,
        repository: FHIRExchangeIdentifiers.SourceRepository,
        converterRole: ConverterRole = .assembler,
        repositoryIDs: [ExchangeGraphNode: RepositoryID] = [:]
    ) throws -> ExchangeEventContext {
        let scope = try identityScope()
        return ExchangeEventContext(
            subject: .logical(subject.identity),
            event: try eventIdentifier(for: event, in: scope),
            identityScope: scope,
            repositoryScope: try repositoryScope(repository, subject: subject),
            application: try event.facts.application,
            host: try event.facts.host,
            conversionInstant: event.recordedAt,
            converterRole: converterRole,
            studies: try event.facts.studies(for: subject),
            repositoryIDs: repositoryIDs
        )
    }
}


extension PersistedFHIRExchangeEvent {
    var sourceTimeZone: TimeZone {
        get throws {
            guard let timeZone = TimeZone(identifier: sourceTimeZoneIdentifier) else {
                throw FHIRExchangeStateError.invalidPersistedTimeZone(sourceTimeZoneIdentifier)
            }
            return timeZone
        }
    }
}
