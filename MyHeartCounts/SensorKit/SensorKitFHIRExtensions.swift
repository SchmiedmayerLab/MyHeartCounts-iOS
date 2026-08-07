//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import ModelsR4
import SpeziSensorKit


extension FHIRExtensionBuilder where Input == SensorKit.DeviceInfo {
    static var sensorKitSourceDevice: Self {
        Self { (deviceInfo: SensorKit.DeviceInfo, observation) in
            observation.append(
                extension: Extension(
                    extension: [
                        Extension(
                            url: FHIRExtensionURL.sensorKitSourceDevice.appending(component: "model"),
                            value: .string(deviceInfo.model.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionURL.sensorKitSourceDevice.appending(component: "name"),
                            value: .string(deviceInfo.name.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionURL.sensorKitSourceDevice.appending(component: "systemName"),
                            value: .string(deviceInfo.systemName.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionURL.sensorKitSourceDevice.appending(component: "systemVersion"),
                            value: .string(deviceInfo.systemVersion.asFHIRStringPrimitive())
                        ),
                        Extension(
                            url: FHIRExtensionURL.sensorKitSourceDevice.appending(component: "productType"),
                            value: .string(deviceInfo.productType.asFHIRStringPrimitive())
                        )
                    ],
                    url: FHIRExtensionURL.sensorKitSourceDevice
                ),
                behaviour: .replace
            )
        }
    }
}


extension FHIRExtensionURL {
    static let sensorKitDomain = Self("https://bdh.stanford.edu/fhir/defs/SensorKit")
    static let sensorKitSourceDevice = Self("https://bdh.stanford.edu/fhir/defs/SensorKit/sourceDevice")
}
