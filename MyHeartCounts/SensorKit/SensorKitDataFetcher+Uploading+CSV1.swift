//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveFoundation
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
import MyHeartCountsShared


/// A SensorKit sample that can be appended to a tabular recording.
///
/// Columns come from the registry format the stream declares; the app chooses neither.
/// Why a tabular upload could not be written.
enum SensorKitUploadError: Error {
    /// The stream declares a registry format that publishes no column set.
    case formatIsNotTabular(RegisteredRecordingFormat)
}


protocol CSVAppendableSensorSample: Sendable {
    /// The registry format this stream writes; its published columns are the ones emitted.
    static var recordingFormat: RegisteredRecordingFormat { get }

    /// This sample's values for every column but the trailing device column.
    var recordingFields: [RecordingCSVWriter.Field] { get }
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
        guard let columns = Sample.SafeRepresentation.recordingFormat.csvColumns else {
            throw SensorKitUploadError.formatIsNotTabular(Sample.SafeRepresentation.recordingFormat)
        }
        var writer = RecordingCSVWriter(columns: columns)
        activity.updateMessage("Writing to CSV")
        let device = RecordingCSVWriter.Field.text(batchInfo.device.description)
        var minDate = firstSample.timeRange.lowerBound
        var maxDate = firstSample.timeRange.upperBound
        for sample in samples {
            try writer.append(sample.recordingFields + [device])
            minDate = min(minDate, sample.timeRange.lowerBound)
            maxDate = max(maxDate, sample.timeRange.upperBound)
        }
        try await upload(
            data: writer.data(),
            for: sensor,
            deviceInfo: batchInfo.device,
            effectiveTimeRange: minDate..<maxDate,
            to: standard,
            documentName: "\(batchInfo.timeRange.lowerBound.ISO8601Format())_\(batchInfo.timeRange.upperBound.ISO8601Format())",
            activity: activity
        )
    }
}
