//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit


/// A strategy for uploading SensorKit samples.
protocol MHCSensorSampleUploadStrategy<Sample>: Sendable {
    /// The strategy's sensor sample type.
    associatedtype Sample: SensorKitSampleProtocol
    
    func upload(
        _ samples: consuming some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        batchInfo: SensorKit.BatchInfo,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws
}


/// A type-erased version of a ``MHCSensorUploadDefinition``
protocol AnyMHCSensorUploadDefinition<Sample, UploadStrategy>: Sendable {
    associatedtype Sample: SensorKitSampleProtocol
    associatedtype UploadStrategy: MHCSensorSampleUploadStrategy where UploadStrategy.Sample == Sample
    
    var sensor: Sensor<Sample> { get }
    // periphery:ignore - API
    var strategy: UploadStrategy { get }
}


/// Associates a SensorKit `Sensor` with an upload strategy.
///
/// - Note: There can exist multiple upload definitions per sensor;
///     which upload definitions a sensor supports is determined based on the upload-related protocols the sensor conforms to.
struct MHCSensorUploadDefinition<
    Sample: SensorKitSampleProtocol,
    UploadStrategy: MHCSensorSampleUploadStrategy<Sample>
>: AnyMHCSensorUploadDefinition {
    typealias Sample = Sample
    typealias UploadStrategy = UploadStrategy
    
    /// The sensor
    let sensor: Sensor<Sample>
    /// The upload strategy.
    let strategy: UploadStrategy
    
    init(sensor: Sensor<Sample>, strategy: UploadStrategy) {
        self.sensor = sensor
        self.strategy = strategy
    }
    
    init(_ typeErased: any AnyMHCSensorUploadDefinition<Sample, UploadStrategy>) {
        // SAFETY: `MHCSensorDefinition` is the only type allowed to conform to `AnyMHCSensorDefinition`.
        self = typeErased as! Self // swiftlint:disable:this force_cast
    }
}

extension AnyMHCSensorUploadDefinition {
    var typeErasedSensor: any AnySensor {
        sensor
    }
}
