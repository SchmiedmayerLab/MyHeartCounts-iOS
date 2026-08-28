//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveSensorKit
import ModelsR4


/// A SensorKit sample that can be turned into a CSV file representing this singular sample.
///
/// This protocol is intended for sample types that represent a session of several individual measurements, instead of being a measurement in their own right.
/// (E.g., the wrist temperature samples.)
protocol CSVConvertibleSensorSample: Sendable {
    func csvData() throws -> Data
    
    /// Gives the sample the opportunity to modify the recording document created from it.
    func finalize(_ document: inout ModelsR4.DocumentReference) throws
}


/// An upload strategy that encodes a batch of samples into a CSV files, uploads that, and creates a corresponding FHIR observation.
struct UploadStrategyCSVFile2<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: CSVConvertibleSensorSample & Identifiable, Sample.SafeRepresentation.ID == UUID {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        batchInfo: SensorKit.BatchInfo,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        for sample in samples {
            activity.updateMessage("Writing to CSV")
            let csvData = try sample.csvData()
            try await upload(
                data: csvData,
                for: sensor,
                deviceInfo: batchInfo.device,
                effectiveTimeRange: sample.timeRange,
                recordID: sample.id,
                to: standard,
                documentName: sample.id.uuidString,
                activity: activity
            ) { document in
                try sample.finalize(&document)
            }
        }
    }
}


extension DefaultSensorKitSampleSafeRepresentation: CSVConvertibleSensorSample where Sample: CSVConvertibleSensorSample {
    func csvData() throws -> Data {
        try sample.csvData()
    }
    
    func finalize(_ document: inout ModelsR4.DocumentReference) throws {
        try sample.finalize(&document)
    }
}
