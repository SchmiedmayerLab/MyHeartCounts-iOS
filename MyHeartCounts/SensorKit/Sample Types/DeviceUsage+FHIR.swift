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
import SensorKit
import SpeziHealthKitFHIR
import SpeziSensorKit


extension SRDeviceUsageReport.SafeRepresentation: HealthObservation {
    var id: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(self.timestamp)
        hasher.combine(self.duration)
        hasher.combine(self.totalScreenWakes)
        hasher.combine(self.totalUnlocks)
        hasher.combine(self.totalUnlockDuration)
        hasher.combine(self.version)
        hasher.combine(self.appUsageByCategory.count)
        hasher.combine(self.notificationUsageByCategory.count)
        hasher.combine(self.webUsageByCategory.count)
        return hasher.finalize()
    }
    
    var sampleTypeIdentifier: String {
        Sensor.deviceUsage.id
    }
    
    func resource( // swiftlint:disable:this function_body_length
        withMapping mapping: SampleTypesFHIRMapping,
        issuedDate: FHIRPrimitive<Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ResourceProxy {
        var observation = Observation(
            code: CodeableConcept(),
            status: FHIRPrimitive(.final)
        )
        let sensorCoding = SensorKitCodingSystem(.deviceUsage)
        observation.id = self.id.uuidString.asFHIRStringPrimitive()
        observation.append(identifier: Identifier(id: observation.id))
        observation.append(coding: Coding(code: sensorCoding))
        if let issuedDate {
            observation.issued = issuedDate
        } else {
            try observation.setIssued(on: .now)
        }
        observation.effective = try .period(Period(
            end: FHIRPrimitive(DateTime(date: self.timestamp + self.duration)),
            start: FHIRPrimitive(DateTime(date: self.timestamp))
        ))
        observation.value = .quantity(Quantity(unit: .second, value: self.totalUnlockDuration))
        
        let sensorDomainUrl = FHIRExtensionURL.sensorKitDomain.appending(component: "DeviceUsage")
        observation.append(extensions: [
            Extension(
                url: sensorDomainUrl.appending(component: "totalScreenWakes"),
                value: .integer(self.totalScreenWakes.asFHIRIntegerPrimitive())
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "totalUnlocks"),
                value: .integer(self.totalUnlocks.asFHIRIntegerPrimitive())
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "totalUnlockDuration"),
                value: .quantity(Quantity(unit: .second, value: self.totalUnlockDuration))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "version"),
                value: .string(self.version.asFHIRStringPrimitive())
            )
        ], behaviour: .replace)
        
        for (category, usages) in self.appUsageByCategory {
            let appUsageUrl = sensorDomainUrl.appending(component: "appUsage")
            for usage in usages {
                var usageExt = Extension(url: appUsageUrl)
                usageExt.append(
                    extension: Extension(
                        url: appUsageUrl.appending(component: "category"),
                        value: .string(category.rawValue.asFHIRStringPrimitive())
                    ),
                    behaviour: .additive
                )
                usageExt.append(
                    extension: Extension(
                        url: appUsageUrl.appending(component: "bundleIdentifier"),
                        value: usage.bundleIdentifier.map { .string($0.asFHIRStringPrimitive()) }
                    ),
                    behaviour: .additive
                )
                usageExt.append(
                    extension: Extension(
                        url: appUsageUrl.appending(component: "relativeStartTime"),
                        value: .decimal(usage.relativeStartTime.asFHIRDecimalPrimitive())
                    ),
                    behaviour: .additive
                )
                usageExt.append(
                    extension: Extension(
                        url: appUsageUrl.appending(component: "usageTime"),
                        value: .quantity(Quantity(unit: .second, value: usage.usageTime))
                    ),
                    behaviour: .additive
                )
                usageExt.append(
                    extension: Extension(
                        url: appUsageUrl.appending(component: "reportApplicationIdentifier"),
                        value: .string(usage.reportApplicationIdentifier.asFHIRStringPrimitive())
                    ),
                    behaviour: .additive
                )
                for session in usage.textInputSessions {
                    let sessionUrl = appUsageUrl.appending(component: "textInputSession")
                    usageExt.append(
                        extension: Extension(
                            extension: [
                                Extension(
                                    url: sessionUrl.appending(component: "identifier"),
                                    value: .string(session.identifier.asFHIRStringPrimitive())
                                ),
                                Extension(
                                    url: sessionUrl.appending(component: "duration"),
                                    value: .quantity(Quantity(unit: .second, value: session.duration))
                                ),
                                Extension(
                                    url: sessionUrl.appending(component: "type"),
                                    value: .integer(session.sessionType.rawValue.asFHIRIntegerPrimitive())
                                )
                            ],
                            url: sessionUrl
                        ),
                        behaviour: .additive
                    )
                }
                for category in usage.supplementalCategories {
                    usageExt.append(
                        extension: Extension(
                            url: appUsageUrl.appending(component: "supplementalCategory"),
                            value: .string(category.identifier.asFHIRStringPrimitive())
                        ),
                        behaviour: .additive
                    )
                }
                observation.append(extension: usageExt, behaviour: .additive)
            }
        }
        
        for (category, usages) in self.notificationUsageByCategory {
            let usageUrl = sensorDomainUrl.appending(component: "notificationUsage")
            for usage in usages {
                observation.append(
                    extension: Extension(
                        extension: [
                            Extension(
                                url: usageUrl.appending(component: "category"),
                                value: .string(category.rawValue.asFHIRStringPrimitive())
                            ),
                            Extension(
                                url: usageUrl.appending(component: "bundleIdentifier"),
                                value: usage.bundleIdentifier.map { .string($0.asFHIRStringPrimitive()) }
                            ),
                            Extension(
                                url: usageUrl.appending(component: "event"),
                                value: .integer(usage.event.rawValue.asFHIRIntegerPrimitive())
                            )
                        ],
                        url: usageUrl
                    ),
                    behaviour: .additive
                )
            }
        }
        
        for (category, webUsages) in self.webUsageByCategory {
            let webUsageUrl = sensorDomainUrl.appending(component: "webUsage")
            for webUsage in webUsages {
                observation.append(
                    extension: Extension(
                        extension: [
                            Extension(
                                url: webUsageUrl.appending(component: "category"),
                                value: .string(category.rawValue.asFHIRStringPrimitive())
                            ),
                            Extension(
                                url: webUsageUrl.appending(component: "totalUsageTime"),
                                value: .quantity(Quantity(unit: .second, value: webUsage.totalUsageTime))
                            )
                        ],
                        url: webUsageUrl
                    ),
                    behaviour: .additive
                )
            }
        }
        
        for builder in extensions {
            try builder.apply(typeErasedInput: self, to: &observation)
        }
        observation.addMHCAppAsSource()
        return .observation(observation)
    }
}
