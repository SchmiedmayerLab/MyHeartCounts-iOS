//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveSensorKit
import ModelsR4


extension FHIRExtensionBuilder where Input == SensorKit.DeviceInfo {
    static var sensorKitSourceDevice: Self {
        Self { (deviceInfo: SensorKit.DeviceInfo, resource) in
            resource.append(
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
