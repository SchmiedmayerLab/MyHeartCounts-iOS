//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4
import SpeziFoundation
import SpeziSensorKit


/// A SensorKit sample that can be turned into a CSV file representing this singular sample.
///
/// This protocol is intended for sample types that represent a session of several individual measurements, instead of being a measurement in their own right.
/// (E.g., the wrist temperature samples.)
protocol CSVConvertibleSensorSample: Sendable {
    func csvData() throws -> Data
    
    /// Gives the sample the opportunity to modify the `Observation` created from it (that points to the CSV file created from the sample).
    func finalize(_ observation: inout Observation) throws
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
                fileExtension: "csv",
                for: sensor,
                deviceInfo: batchInfo.device,
                to: standard,
                observationDocName: sample.id.uuidString,
                activity: activity
            ) { observation in
                observation.effective = try .period(Period(
                    end: FHIRPrimitive(DateTime(date: sample.timeRange.upperBound)),
                    start: FHIRPrimitive(DateTime(date: sample.timeRange.lowerBound))
                ))
                try sample.finalize(&observation)
            }
        }
    }
}


extension DefaultSensorKitSampleSafeRepresentation: CSVConvertibleSensorSample where Sample: CSVConvertibleSensorSample {
    func csvData() throws -> Data {
        try sample.csvData()
    }
    
    func finalize(_ observation: inout Observation) throws {
        try sample.finalize(&observation)
    }
}
