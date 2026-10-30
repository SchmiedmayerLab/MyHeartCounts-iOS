//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import ModelsDSTU2
import ModelsR4


/// Identifies the My Heart Counts build which created a FHIR resource.
///
/// Encoded into every FHIR resource the app uploads, under `FHIRExtensionURL.mhcAppRevision`:
/// ```json
/// {
///   "url": "https://myheartcounts.stanford.edu/fhir/core/mhcAppRevision",
///   "extension": [
///     { "url": "https://myheartcounts.stanford.edu/fhir/core/mhcAppRevision/version", "valueString": "4.2.1" },
///     { "url": "https://myheartcounts.stanford.edu/fhir/core/mhcAppRevision/build", "valueInteger": 123 },
///     { "url": "https://myheartcounts.stanford.edu/fhir/core/mhcAppRevision/bundleIdentifier", "valueString": "edu.stanford.MyHeartCounts" },
///     { "url": "https://myheartcounts.stanford.edu/fhir/core/mhcAppRevision/osVersion", "valueString": "26.5.0" }
///   ]
/// }
/// ```
///
/// - Important: This is **not** the same as `FHIRExtensionURL.sourceRevision`. `sourceRevision` identifies the origin of the
///     underlying *sample* (e.g. the Apple Watch which recorded a heart rate sample, or the health system which supplied a
///     clinical record), and for HealthKit samples is written by GroveHealthKitFHIR. This extension always identifies the
///     My Heart Counts build which performed the conversion into FHIR.
enum MHCAppRevision {
    /// A single child of the `FHIRExtensionURL.mhcAppRevision` extension.
    fileprivate enum Field {
        case string(component: String, value: String)
        case integer(component: String, value: Int)

        var url: FHIRExtensionURL {
            switch self {
            case .string(let component, _), .integer(let component, _):
                FHIRExtensionURL.mhcAppRevision.appending(component: component)
            }
        }
    }

    /// The app's marketing version (`CFBundleShortVersionString`), e.g. `"4.2.1"`.
    static let version: String = Bundle.main.appVersion
    /// The app's build number (`CFBundleVersion`), e.g. `123`.
    ///
    /// `nil` if the value is absent or not an integer, in which case the `build` child extension is omitted.
    static let build: Int? = Bundle.main.appBuildNumber
    /// The app's bundle identifier.
    static let bundleIdentifier: String? = Bundle.main.bundleIdentifier
    /// The operating system version the resource was created on, e.g. `"26.5.0"`.
    static let osVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    /// The children of the `FHIRExtensionURL.mhcAppRevision` extension, in a stable order.
    fileprivate static let fields: [Field] = {
        var fields: [Field] = [.string(component: "version", value: version)]
        if let build {
            fields.append(.integer(component: "build", value: build))
        }
        if let bundleIdentifier {
            fields.append(.string(component: "bundleIdentifier", value: bundleIdentifier))
        }
        fields.append(.string(component: "osVersion", value: osVersion))
        return fields
    }()
}


extension FHIRExtensionURL {
    /// Url of a FHIR Extension identifying the My Heart Counts build which created the resource.
    ///
    /// See ``MHCAppRevision``.
    static let mhcAppRevision = Self("https://myheartcounts.stanford.edu/fhir/core/mhcAppRevision")
}


// MARK: FHIR Encoding

extension ModelsR4.Extension {
    /// A FHIR Extension identifying the My Heart Counts build which created the resource.
    ///
    /// Invariant for the lifetime of the process.
    static let mhcAppRevision: Self = {
        let children: [Self] = MHCAppRevision.fields.map { (field: MHCAppRevision.Field) -> Self in
            switch field {
            case let .string(_, value):
                return Self(url: field.url, value: .string(value.asFHIRStringPrimitive()))
            case let .integer(_, value):
                return Self(url: field.url, value: .integer(value.asFHIRIntegerPrimitive()))
            }
        }
        return Self(extension: children, url: FHIRExtensionURL.mhcAppRevision)
    }()
}


extension ModelsDSTU2.Extension {
    /// A FHIR Extension identifying the My Heart Counts build which created the resource.
    ///
    /// Invariant for the lifetime of the process.
    static let mhcAppRevision: Self = {
        let children: [Self] = MHCAppRevision.fields.map { (field: MHCAppRevision.Field) -> Self in
            switch field {
            case let .string(_, value):
                return Self(url: field.url.dstu2, value: .string(value.asFHIRStringPrimitive()))
            case let .integer(_, value):
                return Self(url: field.url.dstu2, value: .integer(value.asFHIRIntegerPrimitive()))
            }
        }
        return Self(extension: children, url: FHIRExtensionURL.mhcAppRevision.dstu2)
    }()
}


// MARK: Application

extension FHIRExtensionBuilderProtocol where Self == FHIRExtensionBuilder<Void> {
    /// A FHIR Extension Builder which writes the ``MHCAppRevision`` into a FHIR resource.
    ///
    /// Part of `MyHeartCountsStandard.defaultHealthObservationFHIRExtensions`, i.e. applied to every FHIR resource
    /// created from a ``HealthObservation``.
    static var mhcAppRevision: Self {
        .init { resource in
            resource.append(extension: .mhcAppRevision, behaviour: .replace)
        }
    }
}


extension ModelsR4.DomainResource {
    /// Writes the ``MHCAppRevision`` into the resource, replacing any already-present `mhcAppRevision` extension.
    ///
    /// Exists in addition to the ``FHIRExtensionBuilderProtocol/mhcAppRevision`` extension builder because
    /// `ModelsR4.DomainResource` (used for the clinical record passthrough) does not conform to `FHIRTypeWithExtensions`.
    mutating func addMHCAppRevision() {
        var extensions = self.extension ?? []
        extensions.removeAll { $0.url == FHIRExtensionURL.mhcAppRevision.r4 }
        extensions.append(.mhcAppRevision)
        self.extension = extensions
    }
}


extension ModelsDSTU2.DomainResource {
    /// Writes the ``MHCAppRevision`` into the resource, replacing any already-present `mhcAppRevision` extension.
    mutating func addMHCAppRevision() {
        var extensions = self.extension ?? []
        extensions.removeAll { $0.url == FHIRExtensionURL.mhcAppRevision.dstu2 }
        extensions.append(.mhcAppRevision)
        self.extension = extensions
    }
}
