//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import Foundation
import GroveFoundation
import GroveSensorKit
import ModelsR4
import MyHeartCountsShared


/// A SensorKit sample that can be appended to a CSV file containing a collection of samples of this type.
protocol CSVAppendableSensorSample: Sendable {
    /// The CSV columns required to CSV-encode an instance of this type.
    static var csvColumns: [String] { get }
    
    /// This sample's values for the columns defined in ``csvColumns``
    var csvFieldValues: [any CSVWriter.FieldValue] { get }
}


/// An upload strategy that encodes a batch of samples into a CSV files, uploads that, and creates a corresponding FHIR observation.
struct UploadStrategyCSVFile<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: CSVAppendableSensorSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        batchInfo: SensorKit.BatchInfo,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        guard let firstSample = samples.first else {
            return
        }
        let writer = try CSVWriter(columns: Sample.SafeRepresentation.csvColumns + ["device"])
        activity.updateMessage("Writing to CSV")
        let deviceInfoCol = CollectionOfOne<any CSVWriter.FieldValue>(batchInfo.device.description)
        for sample in samples {
            try writer.appendRow(fields: chain(sample.csvFieldValues, deviceInfoCol))
        }
        try await upload(
            data: writer.data(),
            fileExtension: "csv",
            for: sensor,
            deviceInfo: batchInfo.device,
            to: standard,
            observationDocName: "\(batchInfo.timeRange.lowerBound.ISO8601Format())_\(batchInfo.timeRange.upperBound.ISO8601Format())",
            activity: activity
        ) { observation in
            let (minDate, maxDate) = {
                var minDate = firstSample.timeRange.lowerBound
                var maxDate = firstSample.timeRange.upperBound
                for sample in samples {
                    minDate = min(minDate, sample.timeRange.lowerBound)
                    maxDate = max(maxDate, sample.timeRange.upperBound)
                }
                return (minDate, maxDate)
            }()
            observation.effective = try .period(Period(
                end: FHIRPrimitive(DateTime(date: maxDate)),
                start: FHIRPrimitive(DateTime(date: minDate))
            ))
        }
    }
}
