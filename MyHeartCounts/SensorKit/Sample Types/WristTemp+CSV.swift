//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKitFHIR
import ModelsR4
import MyHeartCountsShared
import SensorKit
import SpeziFoundation
import SpeziSensorKit
import FHIRModelsExtensions


extension SRWristTemperatureSession: CSVConvertibleSensorSample {
    func csvData() throws -> Data {
        let writer = try CSVWriter(columns: ["timestamp", "value", "errorEstimate", "condition"])
        for temp in self.temperatures {
            try writer.appendRow(fields: [
                temp.timestamp,
                temp.value.converted(to: .celsius).value,
                temp.errorEstimate.converted(to: .celsius).value,
                temp.condition.stringValue
            ] as [any CSVWriter.FieldValue])
        }
        return writer.data()
    }
    
    func finalize(_ observation: Observation) throws {
        observation.id = self.id.uuidString.asFHIRStringPrimitive()
        observation.appendExtensions([
            Extension(
                url: FHIRExtensionUrls.sensorKitWristTempAlgorithmVersion,
                value: .string(self.version.asFHIRStringPrimitive())
            )
        ], replaceAllExistingWithSameUrl: true)
    }
}


extension SRWristTemperature.Condition {
    var stringValue: String {
        // NOTE: `SRWristTemperature.Condition` is an OptionSet, meaning that we can't statically enumerate all cases, e.g. via a switch.
        // Apple could add additional cases in the future; we'd need to adjust the code below in that case.
        var values: [String] = []
        if self.contains(.offWrist) {
            values.append("offWrist")
        }
        if self.contains(.onCharger) {
            values.append("onCharger")
        }
        if self.contains(.inMotion) {
            values.append("inMotion")
        }
        return values.joined(separator: ",")
    }
}


extension FHIRExtensionUrls {
    nonisolated(unsafe) static let sensorKitWristTempAlgorithmVersion = Self.sensorKitDomain.appending(component: "WristTemp/algorithmVersion")
}
