//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import UIKit


/// The application, host, and study facts every record a producer converts states.
struct ConversionFacts: Codable, Equatable, Sendable {
    struct Study: Codable, Equatable, Sendable {
        let id: String
        let revision: UInt
    }

    let applicationName: String
    let applicationBundleIdentifier: String
    let applicationVersion: String
    let applicationBuild: String?
    let hostOperatingSystemName: String?
    let hostOperatingSystemVersion: String
    let hostOperatingSystemBuild: String?
    let hostProductType: String?
    let hostModel: String?
    let hostName: String?
    let hostManufacturer: String?
    let study: Study?

    init(application: ApplicationDevice, host: HostDevice, study: Study?) {
        self.applicationName = application.name
        self.applicationBundleIdentifier = application.bundleIdentifier
        self.applicationVersion = application.version
        self.applicationBuild = application.build
        self.hostOperatingSystemName = host.operatingSystemName
        self.hostOperatingSystemVersion = host.operatingSystemVersion
        self.hostOperatingSystemBuild = host.operatingSystemBuild
        self.hostProductType = host.productType
        self.hostModel = host.model
        self.hostName = host.name
        self.hostManufacturer = host.manufacturer
        self.study = study
    }

    /// The facts as they stand right now, for the records about to be converted.
    static func current() async throws -> Self {
        Self(
            application: try ApplicationDevice(bundle: .main),
            host: try await .currentWithUIDeviceFacts(),
            study: MyHeartCountsStandard.currentEnrollmentInfo.map {
                Study(id: $0.studyId, revision: $0.studyRevision)
            }
        )
    }
}


extension HostDevice {
    /// A snapshot of the current host, with the facts `UIDevice` holds on the main actor.
    ///
    /// A blank `UIDevice` fact is stated as absent, as a Device snapshot cannot name it.
    fileprivate static func currentWithUIDeviceFacts() async throws -> Self {
        func stated(_ fact: String) -> String? {
            fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fact
        }
        let host = HostDevice.current()
        return try await MainActor.run {
            let device = UIDevice.current
            return try HostDevice(
                operatingSystemName: stated(device.systemName),
                operatingSystemVersion: host.operatingSystemVersion,
                operatingSystemBuild: host.operatingSystemBuild,
                productType: host.productType,
                model: stated(device.model),
                name: stated(device.name),
                manufacturer: "Apple"
            )
        }
    }
}


extension ConversionFacts {
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
                operatingSystemName: hostOperatingSystemName,
                operatingSystemVersion: hostOperatingSystemVersion,
                operatingSystemBuild: hostOperatingSystemBuild,
                productType: hostProductType,
                model: hostModel,
                name: hostName,
                manufacturer: hostManufacturer
            )
        }
    }

    /// The enrollment a record is relevant to, stated with the exact protocol revision it ran under.
    func studies(for subject: FHIRExchangeSubject) throws -> [StudyEnrollment] {
        guard let study else {
            return []
        }
        let studyID = study.id.lowercased()
        return [
            try StudyEnrollment(
                study: BusinessIdentifier(system: FHIRExchangeIdentifiers.researchStudy, value: studyID),
                protocolURL: FHIRExchangeIdentifiers.studyProtocol(studyID: studyID),
                protocolVersion: String(study.revision),
                enrollment: BusinessIdentifier(
                    system: FHIRExchangeIdentifiers.researchSubject,
                    value: "\(studyID):\(subject.identity.value)"
                )
            )
        ]
    }
}
