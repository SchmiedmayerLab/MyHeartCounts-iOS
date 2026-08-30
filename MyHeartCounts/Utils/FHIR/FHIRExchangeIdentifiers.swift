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

    static var pseudonymousSystems: PseudonymousIdentitySystems {
        get throws {
            let root = "https://myheartcounts.stanford.edu/fhir/identifiers/pseudonym"
            return try PseudonymousIdentitySystems(
                sourceRecord: IdentifierSystem("\(root)/source-record-v0/installation/1"),
                sourceOutput: IdentifierSystem("\(root)/source-output-v0/installation/1"),
                writerRecord: IdentifierSystem("\(root)/writer-record-v0/installation/1"),
                providerRecord: IdentifierSystem("\(root)/provider-record-v0/installation/1"),
                providerOutput: IdentifierSystem("\(root)/provider-output-v0/installation/1"),
                sourceArtifact: IdentifierSystem("\(root)/source-artifact-v0/installation/1"),
                providerArtifact: IdentifierSystem("\(root)/provider-artifact-v0/installation/1"),
                sourceContext: IdentifierSystem("\(root)/source-context-v0/installation/1"),
                recordingDevice: IdentifierSystem("\(root)/recording-device-v0/installation/1"),
                deviceSnapshot: IdentifierSystem("\(root)/device-snapshot-v0/installation/1")
            )
        }
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
            name: applicationName,
            bundleIdentifier: applicationToken,
            version: applicationVersion ?? "0",
            build: applicationBuild
        )
    }

    var healthKitHost: HealthKitHostDevice {
        HealthKitHostDevice(
            sourceDeviceToken: hostToken,
            operatingSystemVersion: hostOperatingSystemVersion,
            name: hostName,
            manufacturer: hostManufacturer,
            modelNumber: hostModelNumber
        )
    }

    var sensorApplication: SensorApplication {
        SensorApplication(
            sourceDeviceToken: applicationToken,
            name: applicationName,
            version: applicationVersion,
            build: applicationBuild
        )
    }

    var sensorHost: SensorHostDevice {
        SensorHostDevice(
            sourceDeviceToken: hostToken,
            operatingSystemVersion: hostOperatingSystemVersion,
            name: hostName,
            manufacturer: hostManufacturer,
            modelNumber: hostModelNumber
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
