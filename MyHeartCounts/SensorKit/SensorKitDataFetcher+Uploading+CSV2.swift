//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
import GroveSensorKitFHIR


/// A SensorKit sample that can be turned into a CSV file representing this singular sample.
///
/// This protocol is intended for sample types that represent a session of several individual measurements, instead of being a measurement in their own right.
/// (E.g., the wrist temperature samples.)
protocol CSVConvertibleSensorSample: Sendable {
    func csvData() throws -> Data

    func retryEvidence(csvData: Data) -> Data

    func groveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        nativeRecording: SensorKitNativeRecording
    ) throws -> SensorKitRecord
}


/// An upload strategy that encodes a batch of samples into a CSV files, uploads that, and creates a corresponding FHIR observation.
struct UploadStrategyCSVFile2<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: CSVConvertibleSensorSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        for (recordOrdinal, sample) in samples.enumerated() {
            activity.updateMessage("Writing to CSV")
            let csvData = try sample.csvData()
            try await upload(
                data: csvData,
                for: sensor,
                effectiveTimeRange: sample.timeRange,
                publication: publication,
                to: standard,
                activity: activity,
                recordOrdinal: recordOrdinal,
                retryEvidence: sample.retryEvidence(csvData: csvData)
            ) { sourceRecordID, nativeRecording in
                try sample.groveRecord(
                    sourceRecordID: sourceRecordID,
                    nativeRecording: nativeRecording
                )
            }
        }
    }
}


extension DefaultSensorKitSampleSafeRepresentation: CSVConvertibleSensorSample where Sample: CSVConvertibleSensorSample {
    func csvData() throws -> Data {
        try sample.csvData()
    }
    
    func retryEvidence(csvData: Data) -> Data {
        sample.retryEvidence(csvData: csvData)
    }

    func groveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        nativeRecording: SensorKitNativeRecording
    ) throws -> SensorKitRecord {
        try sample.groveRecord(
            sourceRecordID: sourceRecordID,
            nativeRecording: nativeRecording
        )
    }
}
