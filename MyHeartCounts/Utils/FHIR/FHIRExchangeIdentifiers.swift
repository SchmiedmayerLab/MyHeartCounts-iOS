//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import GroveSensorKitFHIR
import ModelsR4


enum FHIRExchangeIdentifiers {
    enum SourceRepository: String, Sendable {
        case healthKit = "healthkit"
        case questionnaire = "questionnaire"
        case sensorKit = "sensorkit"
    }

    static let application: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/application"
    static let participant: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/participant"
    static let researchStudy: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/research-study"
    static let repository: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/repository"
    static let event: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/exchange-event"
    static let entryNode: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/entry-node"
    static let healthKitNativeRecord: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/healthkit-record"
    static let sensorKitSourceRecord: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/sensorkit-record"
    static let visitLocation: IdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/sensorkit-visit-location"

    /// The wire-visible key id selecting the store-bound secret every identity is minted from.
    static let identityKeyID = "store"

    private static let pseudonymRoot = "https://myheartcounts.stanford.edu/fhir/identifiers/pseudonym"

    /// The ten systems for one identity scope, each naming the key id and epoch minting under it.
    ///
    /// Derived from the scope rather than written out, so a system can never claim a key id or
    /// epoch the values carried under it contradict.
    static func pseudonymousSystems(
        keyID: String,
        epoch: CanonicalPositiveDecimal
    ) throws -> PseudonymousIdentitySystems {
        func system(_ kind: String) throws -> IdentifierSystem {
            try IdentifierSystem("\(pseudonymRoot)/\(kind)-v0/\(keyID)/\(epoch.rawValue)")
        }
        return try PseudonymousIdentitySystems(
            sourceRecord: system("source-record"),
            sourceOutput: system("source-output"),
            writerRecord: system("writer-record"),
            providerRecord: system("provider-record"),
            providerOutput: system("provider-output"),
            sourceArtifact: system("source-artifact"),
            providerArtifact: system("provider-artifact"),
            sourceContext: system("source-context"),
            recordingDevice: system("recording-device"),
            deviceSnapshot: system("device-snapshot")
        )
    }

    static func currentResearchStudyIDs() -> [String] {
        guard let enrollment = MyHeartCountsStandard.currentEnrollmentInfo else {
            return []
        }
        return [enrollment.studyId]
    }

    static func researchStudyReferences(for studyIDs: [String]) throws -> [Reference] {
        try studyIDs.map { studyID in
            try BusinessIdentifier(system: researchStudy, value: studyID)
                .reference(to: .researchStudy)
        }
    }
}


extension PersistedFHIRExchangeEvent {
    var healthKitApplication: HealthKitApplication {
        HealthKitApplication(
            name: facts.applicationName,
            bundleIdentifier: facts.applicationToken,
            version: facts.applicationVersion ?? "0",
            build: facts.applicationBuild
        )
    }

    var healthKitHost: HealthKitHostDevice {
        HealthKitHostDevice(
            sourceDeviceToken: facts.hostToken,
            operatingSystemVersion: facts.hostOperatingSystemVersion,
            name: facts.hostName,
            manufacturer: facts.hostManufacturer,
            modelNumber: facts.hostModelNumber
        )
    }

    var sensorApplication: SensorApplication {
        SensorApplication(
            sourceDeviceToken: facts.applicationToken,
            name: facts.applicationName,
            version: facts.applicationVersion,
            build: facts.applicationBuild
        )
    }

    var sensorHost: SensorHostDevice {
        SensorHostDevice(
            sourceDeviceToken: facts.hostToken,
            operatingSystemVersion: facts.hostOperatingSystemVersion,
            name: facts.hostName,
            manufacturer: facts.hostManufacturer,
            modelNumber: facts.hostModelNumber
        )
    }

    var sourceTimeZone: TimeZone {
        get throws {
            guard let timeZone = TimeZone(identifier: sourceTimeZoneIdentifier) else {
                throw FHIRExchangeStateError.invalidPersistedTimeZone(sourceTimeZoneIdentifier)
            }
            return timeZone
        }
    }
}
