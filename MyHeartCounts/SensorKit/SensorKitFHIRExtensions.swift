//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import HealthKitOnFHIR
import ModelsR4
import SpeziSensorKit


extension FHIRExtensionBuilder where Input == SensorKit.DeviceInfo {
    static var sensorKitSourceDevice: Self {
        Self { (deviceInfo: SensorKit.DeviceInfo, observation) in
            observation.appendExtension(
                Extension(
                    extension: [
                        Extension(
                            url: FHIRExtensionUrls.sensorKitSourceDevice.appending(component: "model"),
                            value: .string(deviceInfo.model.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionUrls.sensorKitSourceDevice.appending(component: "name"),
                            value: .string(deviceInfo.name.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionUrls.sensorKitSourceDevice.appending(component: "systemName"),
                            value: .string(deviceInfo.systemName.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionUrls.sensorKitSourceDevice.appending(component: "systemVersion"),
                            value: .string(deviceInfo.systemVersion.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionUrls.sensorKitSourceDevice.appending(component: "productType"),
                            value: .string(deviceInfo.productType.asFHIRStringPrimitive())
                        )
                    ],
                    url: FHIRExtensionUrls.sensorKitSourceDevice
                ),
                replaceAllExistingWithSameUrl: true
            )
        }
    }
}


extension FHIRExtensionUrls {
    // swiftlint:disable force_unwrapping
    nonisolated(unsafe) static let sensorKitDomain = "https://bdh.stanford.edu/fhir/defs/SensorKit".asFHIRURIPrimitive()!
    nonisolated(unsafe) static let sensorKitSourceDevice = "https://bdh.stanford.edu/fhir/defs/SensorKit/sourceDevice".asFHIRURIPrimitive()!
    // swiftlint:enable force_unwrapping
}
