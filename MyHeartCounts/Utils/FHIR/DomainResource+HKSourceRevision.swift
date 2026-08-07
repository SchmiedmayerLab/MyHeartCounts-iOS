//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import ModelsDSTU2
import ModelsR4
import SpeziFHIR


extension HKSourceRevision {
    fileprivate static let mhc = HKSourceRevision(
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


extension ModelsDSTU2.DomainResource {
    mutating func addSourceRevisionExtensions(for sourceRevision: HKSourceRevision) {
        // swiftlint:disable:next force_unwrapping
        let baseUrl: ModelsDSTU2.FHIRPrimitive<ModelsDSTU2.FHIRURI> = "https://bdh.stanford.edu/fhir/defs/sourceRevision".asFHIRURIPrimitive()!
        var deviceInfo = ModelsDSTU2.Extension(url: baseUrl)
        deviceInfo.extension = []
        let fieldUrl = { (components: String...) -> ModelsDSTU2.FHIRPrimitive<ModelsDSTU2.FHIRURI> in
            // swiftlint:disable:next force_unwrapping
            components.reduce(into: baseUrl.value!.url) { url, component in
                url.append(component: component)
            }
            .asFHIRURIPrimitive()
        }
        let appendDeviceInfoEntry = { (keyPath: KeyPath<HKSourceRevision, String?>) in
            guard let name = keyPath._kvcKeyPathString else {
                print("Unable to obtain name for keyPath '\(keyPath)'. Skipping.")
                return
            }
            guard let value = sourceRevision[keyPath: keyPath] else {
                return
            }
            deviceInfo.extension!.append( // swiftlint:disable:this force_unwrapping
                ModelsDSTU2.Extension(
                    url: fieldUrl(name),
                    value: .string(value.asFHIRStringPrimitive())
                )
            )
        }
        deviceInfo.extension!.append( // swiftlint:disable:this force_unwrapping
            ModelsDSTU2.Extension(
                extension: [
                    ModelsDSTU2.Extension(
                        url: fieldUrl("source", "name"),
                        value: .string(sourceRevision.source.name.asFHIRStringPrimitive())
                    ),
                    ModelsDSTU2.Extension(
                        url: fieldUrl("source", "bundleIdentifier"),
                        value: .string(sourceRevision.source.bundleIdentifier.asFHIRStringPrimitive())
                    )
                ],
                url: fieldUrl("source")
            )
        )
        appendDeviceInfoEntry(\.version)
        appendDeviceInfoEntry(\.productType)
        appendDeviceInfoEntry(\.OSVersion)
        if self.extension == nil {
            self.extension = [deviceInfo]
        } else {
            self.extension!.append(deviceInfo) // swiftlint:disable:this force_unwrapping
        }
    }
}


extension ModelsR4.DomainResource {
    mutating func addSourceRevisionExtensions(for sourceRevision: HKSourceRevision) {
        // swiftlint:disable:next force_unwrapping
        let baseUrl: ModelsR4.FHIRPrimitive<ModelsR4.FHIRURI> = "https://bdh.stanford.edu/fhir/defs/sourceRevision".asFHIRURIPrimitive()!
        var deviceInfo = ModelsR4.Extension(url: baseUrl)
        deviceInfo.extension = []
        let fieldUrl = { (components: String...) -> ModelsR4.FHIRPrimitive<ModelsR4.FHIRURI> in
            // swiftlint:disable:next force_unwrapping
            components.reduce(into: baseUrl.value!.url) { url, component in
                url.append(component: component)
            }
            .asFHIRURIPrimitive()
        }
        let appendDeviceInfoEntry = { (keyPath: KeyPath<HKSourceRevision, String?>) in
            guard let name = keyPath._kvcKeyPathString else {
                print("Unable to obtain name for keyPath '\(keyPath)'. Skipping.")
                return
            }
            guard let value = sourceRevision[keyPath: keyPath] else {
                return
            }
            deviceInfo.extension!.append( // swiftlint:disable:this force_unwrapping
                ModelsR4.Extension(
                    url: fieldUrl(name),
                    value: .string(value.asFHIRStringPrimitive())
                )
            )
        }
        deviceInfo.extension!.append( // swiftlint:disable:this force_unwrapping
            ModelsR4.Extension(
                extension: [
                    ModelsR4.Extension(
                        url: fieldUrl("source", "name"),
                        value: .string(sourceRevision.source.name.asFHIRStringPrimitive())
                    ),
                    ModelsR4.Extension(
                        url: fieldUrl("source", "bundleIdentifier"),
                        value: .string(sourceRevision.source.bundleIdentifier.asFHIRStringPrimitive())
                    )
                ],
                url: fieldUrl("source")
            )
        )
        appendDeviceInfoEntry(\.version)
        appendDeviceInfoEntry(\.productType)
        appendDeviceInfoEntry(\.OSVersion)
        if self.extension == nil {
            self.extension = [deviceInfo]
        } else {
            self.extension!.append(deviceInfo) // swiftlint:disable:this force_unwrapping
        }
    }
}


extension HKSourceRevision {
    /// We define this as an optional String objc-compatible property, so that we can encode it into an Extension using the API we have above.
    @objc fileprivate var OSVersion: String? {
        let version = operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
