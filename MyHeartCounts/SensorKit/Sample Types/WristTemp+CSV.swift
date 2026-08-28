//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
import MyHeartCountsShared
import SensorKit


extension SRWristTemperatureSession: CSVConvertibleSensorSample {
    // Wrist temperature has no structured Grove contract, so the algorithm version stays app-defined.
    private static let algorithmVersionExtension: FHIRPrimitive<FHIRURI> =
        "https://myheartcounts.stanford.edu/fhir/sensorkit/wristTemperature/algorithmVersion"

    func csvData() throws -> Data {
        guard let columns = RegisteredRecordingFormat.wristTemperatureSamples.csvColumns else {
            throw SensorKitUploadError.formatIsNotTabular(.wristTemperatureSamples)
        }
        var writer = RecordingCSVWriter(columns: columns)
        for temp in self.temperatures {
            try writer.append([
                .timestamp(temp.timestamp),
                .number(temp.value.converted(to: .celsius).value),
                .number(temp.errorEstimate.converted(to: .celsius).value),
                .text(temp.condition.stringValue)
            ])
        }
        return writer.data()
    }
    
    func finalize(_ document: inout ModelsR4.DocumentReference) throws {
        document.append(
            extension: Extension(
                url: Self.algorithmVersionExtension,
                value: .string(self.version.asFHIRStringPrimitive())
            ),
            behaviour: .replace
        )
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
