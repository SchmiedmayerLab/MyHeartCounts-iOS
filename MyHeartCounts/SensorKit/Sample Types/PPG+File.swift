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
import NIOCore
import NIOFoundationCompat
import SensorKit
import SpeziFoundation
import SpeziSensorKit


extension SRPhotoplethysmogramSample {
    struct UploadStrategy: MHCSensorSampleUploadStrategy {
        typealias Sample = SRPhotoplethysmogramSample
        
        func upload(
            _ samples: consuming some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
            batchInfo: SensorKit.BatchInfo,
            for sensor: Sensor<SRPhotoplethysmogramSample>,
            to standard: MyHeartCountsStandard,
            activity: SensorKitDataFetcher.InProgressActivity
        ) async throws {
            guard let firstSample = samples.first, let lastSample = samples.last else {
                // nothing to do if samples is empty...
                return
            }
            let buffer = try BinaryEncoder.encode((consume samples).lazy.map { PPGSample($0.sample) })
            guard let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes, byteTransferStrategy: .noCopy) else {
                // should probably be unreachable
                assertionFailure("Failed to retrieve Data for encoded PPG samples")
                return
            }
            try await self.upload(
                data: data,
                fileExtension: "mhcPPG",
                shouldCompress: false,
                for: sensor,
                deviceInfo: batchInfo.device,
                to: standard,
                observationDocName: "\(batchInfo.timeRange.lowerBound.ISO8601Format())_\(batchInfo.timeRange.upperBound.ISO8601Format())",
                activity: activity
            ) { observation in
                // it appears that SensorKit returns PPG samples ordered by startDate
                // there are some cases, sometimes, where samples are out of order, but the largest discrepancy we've noticed was
                // a sample at idx N+1 having a startDate that was ~0.008 seconds earlier than the sample at idx N.
                observation.effective = try .period(Period(
                    end: FHIRPrimitive(DateTime(date: lastSample.startDate)),
                    start: FHIRPrimitive(DateTime(date: firstSample.startDate))
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
