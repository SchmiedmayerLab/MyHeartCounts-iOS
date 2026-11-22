//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKitFHIR
import HealthKit


/// A HealthKit sample MHC created but couldn't save into HealthKit, e.g. a value the participant entered without letting
/// MHC save its type into the Health app.
///
/// It is uploaded the way HealthKit's samples are, and its record states MHC as the sample's source, as HealthKit would
/// have had MHC saved the sample (see ``HealthKitFHIRExporter/RecordProvider/unsavedSamples``). Only quantity samples
/// and correlations are supported; uploading another sample fails with ``UnsupportedSampleError``.
struct UnsavedHealthKitSample: HealthObservation {
    /// The sample isn't a quantity sample or a correlation, for which no unsaved record exists.
    struct UnsupportedSampleError: Error {
        let sampleTypeIdentifier: String
    }

    let sample: HKSample

    var id: UUID {
        sample.uuid
    }

    var sampleTypeIdentifier: String {
        sample.sampleType.identifier
    }

    /// - parameter sample: A sample MHC created and didn't save into HealthKit.
    init(_ sample: HKSample) {
        self.sample = sample
    }

    static func export(
        _ batch: some Collection<Self>,
        at instant: Date,
        recordProvider _: HealthKitFHIRExporter.RecordProvider,
        exporter: @autoclosure () throws -> HealthKitFHIRExporter,
        receive: (PreparedHealthObservationFHIRPayload.Entry) throws -> Void
    ) async throws -> HealthKitBatchExport {
        guard !batch.isEmpty else {
            return .empty
        }
        let samples = batch.map(\.sample)
        let exporter = try exporter()
        return try await HealthKitExportLog.record(.live, samples: HealthKitExportLog.counts(samples), exporter: exporter) {
            try await exporter.exportBatch(samples, at: instant, recordProvider: .unsavedSamples, receive: receive)
        }
    }
}
