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
import GroveSensorKitFHIR
import MyHeartCountsShared
import NIOCore
import NIOFoundationCompat
import SensorKit


extension SRPhotoplethysmogramSample {
    struct UploadStrategy: MHCSensorSampleUploadStrategy {
        typealias Sample = SRPhotoplethysmogramSample
        
        func upload(
            _ samples: consuming some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
            publication: SensorKitBatchPublication,
            for sensor: Sensor<SRPhotoplethysmogramSample>,
            to standard: MyHeartCountsStandard,
            activity: SensorKitDataFetcher.InProgressActivity
        ) async throws {
            guard !samples.isEmpty else {
                // nothing to do if samples is empty...
                return
            }
            let records = samples.map { PPGSample($0.sample) }
            let measurementInstants = records.flatMap { record -> [Date] in
                let offsets = [record.nanosecondsSinceStart]
                    + record.opticalSamples.map(\.nanosecondsSinceStart)
                    + record.accelerometerSamples.map(\.nanosecondsSinceStart)
                return offsets.map {
                    record.startDate.addingTimeInterval(Double($0) / 1_000_000_000)
                }
            }
            guard let coverageStart = measurementInstants.min(),
                  let coverageEnd = measurementInstants.max() else {
                throw SensorKitUploadError.invalidCoverage
            }
            let opticalSampleCount = records.lazy.map(\.opticalSamples.count).reduce(0, +)
            let accelerometerSampleCount = records.lazy.map(\.accelerometerSamples.count).reduce(0, +)
            let buffer = try BinaryEncoder.encode(records)
            guard let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes, byteTransferStrategy: .noCopy) else {
                // should probably be unreachable
                assertionFailure("Failed to retrieve Data for encoded PPG samples")
                return
            }
            try await self.upload(
                data: data,
                for: sensor,
                effectiveTimeRange: coverageStart..<coverageEnd,
                publication: publication,
                to: standard,
                activity: activity
            ) { sourceRecordID, nativeRecording in
                .ppg(SensorKitPPGRecord(
                    sourceRecordID: sourceRecordID,
                    coverage: DateInterval(start: coverageStart, end: coverageEnd),
                    recordCount: records.count,
                    opticalSampleCount: opticalSampleCount,
                    accelerometerSampleCount: accelerometerSampleCount,
                    nativeRecording: nativeRecording
                ))
            }
        }
    }
}


extension SRPhotoplethysmogramSample: @retroactive Identifiable {
    public var id: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(startDate)
        hasher.combine(nanosecondsSinceStart)
        hasher.combine(usage.count)
        hasher.combine(opticalSamples.count)
        hasher.combine(accelerometerSamples.count)
        hasher.combine(temperature?.value)
        return hasher.finalize()
    }
}
