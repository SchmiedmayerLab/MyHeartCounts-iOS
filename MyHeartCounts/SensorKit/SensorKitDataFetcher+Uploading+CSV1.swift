//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR


/// A SensorKit sample that can be appended to a tabular recording.
///
/// Columns come from the registry format the stream declares; the app chooses neither.
/// Why a tabular upload could not be written.
enum SensorKitUploadError: Error {
    /// The stream declares a registry format that publishes no column set.
    case formatIsNotTabular(RegisteredRecordingFormat)
    case emptyWristTemperatureSession
    case invalidCoverage
    case unknownWristTemperatureConditionBits(UInt)
}


enum SensorKitBatchStatistics {
    static func distinctRecordingIdentifierCount(_ identifiers: some Sequence<UInt64?>) -> Int {
        Set(identifiers.compactMap { $0 }).count
    }
}


protocol CSVAppendableSensorSample: Sendable {
    /// The registry format this stream writes; its published columns are the ones emitted.
    static var recordingFormat: RegisteredRecordingFormat { get }

    /// This sample's values for every column but the trailing device column.
    var recordingFields: [RecordingCSVWriter.Field] { get }

    /// A native batch identifier when individual rows belong to a larger source batch.
    var recordingBatchIdentifier: UInt64? { get }

    static func structuredGroveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        coverage: DateInterval,
        sampleCount: Int,
        batchCount: Int,
        nativeRecording: SensorKitNativeRecording
    ) -> SensorKitRecord?
}


/// An upload strategy that encodes a batch of samples into a CSV files, uploads that, and creates a corresponding FHIR observation.
struct UploadStrategyCSVFile<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: CSVAppendableSensorSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        publication: SensorKitBatchPublication,
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
        let device = RecordingCSVWriter.Field.text(publication.info.device.description)
        var minDate = firstSample.timeRange.lowerBound
        var maxDate = firstSample.timeRange.upperBound
        for sample in samples {
            try writer.append(sample.recordingFields + [device])
            minDate = min(minDate, sample.timeRange.lowerBound)
            maxDate = max(maxDate, sample.timeRange.upperBound)
        }
        let batchCount = SensorKitBatchStatistics.distinctRecordingIdentifierCount(
            samples.lazy.map(\.recordingBatchIdentifier)
        )
        try await upload(
            data: writer.data(),
            for: sensor,
            effectiveTimeRange: minDate..<maxDate,
            publication: publication,
            to: standard,
            activity: activity
        ) { sourceRecordID, nativeRecording in
            Sample.SafeRepresentation.structuredGroveRecord(
                sourceRecordID: sourceRecordID,
                coverage: DateInterval(start: minDate, end: maxDate),
                sampleCount: samples.count,
                batchCount: batchCount,
                nativeRecording: nativeRecording
            )
        }
    }
}


extension CSVAppendableSensorSample {
    var recordingBatchIdentifier: UInt64? {
        nil
    }

    static func structuredGroveRecord(
        sourceRecordID: SensorKitSourceRecordID,
        coverage: DateInterval,
        sampleCount: Int,
        batchCount: Int,
        nativeRecording: SensorKitNativeRecording
    ) -> SensorKitRecord? {
        nil
    }
}
