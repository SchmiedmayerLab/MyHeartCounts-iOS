//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveHealthKitFHIR
import GroveSensorKit
import ModelsR4
import MyHeartCountsShared


/// An upload strategy that encodes a batch of samples as a JSON array of FHIR resources, uploads the file to firebase storage, and creates a corresponding FHIR Observation referencing the file.
struct UploadStrategyJSONFile<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: HealthObservation {
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
        activity.updateMessage("Encoding FHIR resources to JSON")
        let issuedDate = FHIRPrimitive<ModelsR4.Instant>(try .init(date: .now))
        let resources: [AnyEncodable] = try samples.map { sample in
            var resource = try sample.resource(
                withMapping: .default,
                issuedDate: issuedDate,
                extensions: MyHeartCountsStandard.defaultHealthObservationFHIRExtensions
            )
            switch resource {
            case .observation(var observation):
                try observation.apply(.sensorKitSourceDevice, input: batchInfo.device)
                resource = .observation(observation)
            default:
                break
            }
            return AnyEncodable(resource)
        }
        let data = try JSONEncoder().encode(resources)
        try await upload(
            data: data,
            fileExtension: "json",
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
