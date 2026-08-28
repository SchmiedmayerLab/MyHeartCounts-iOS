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
import MyHeartCountsShared
import NIOCore
import NIOFoundationCompat
import SensorKit


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
            // SensorKit returns PPG samples ordered by startDate; the occasional out-of-order sample
            // has been off by under a hundredth of a second, so the batch endpoints stand.
            try await self.upload(
                data: data,
                for: sensor,
                deviceInfo: batchInfo.device,
                effectiveTimeRange: firstSample.startDate..<lastSample.startDate,
                to: standard,
                documentName: "\(batchInfo.timeRange.lowerBound.ISO8601Format())_\(batchInfo.timeRange.upperBound.ISO8601Format())",
                activity: activity
            )
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
