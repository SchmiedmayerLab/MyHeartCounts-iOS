//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - somehow a false positive but if we add a line-specific ignore comment it doesnt get picked up correctly

import FHIRModelsExtensions
import GroveSensorKit
import ModelsR4


/// An upload strategy that uploads each sample as a FHIR observation.
struct UploadStrategyFHIRObservations<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: HealthObservation {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        batchInfo: SensorKit.BatchInfo,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        activity.updateMessage("Uploading FHIR Observations")
        try await standard.uploadHealthObservations(samples) { resource in
            switch resource {
            case .r4(let inner):
                if var observation = inner as? ModelsR4::Observation {
                    try observation.apply(.sensorKitSourceDevice, input: batchInfo.device)
                    resource = .r4(observation)
                }
            case .dstu2:
                break
            }
        }
    }
}
