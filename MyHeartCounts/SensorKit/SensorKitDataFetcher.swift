//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import Grove
import GroveFoundation
import GroveSensorKit
import MyHeartCountsShared
import OSLog
import UIKit


private enum SensorKitProcessingError: Error {
    case protectedDataUnavailable
}


private struct SensorKitActiveFetch: Sendable {
    let task: Task<Void, any Error>
    let allowance: DeviceBattery.WorkAllowance
}


@Observable
final class SensorKitDataFetcher: ServiceModule, EnvironmentAccessible, @unchecked Sendable { // swiftlint:disable:this type_body_length
    @Observable
    final class InProgressActivity: Hashable, Identifiable, AnyObjectBasedDefaultImpls, Sendable {
        nonisolated let sensor: any AnySensor
        @MainActor private(set) var timeRange: Range<Date>?
        @MainActor private(set) var message = ""
        
        nonisolated fileprivate init(sensor: any AnySensor) {
            self.sensor = sensor
        }
        
        nonisolated func updateMessage(_ newValue: String) {
            Task { @MainActor in
                self.message = newValue
            }
        }
        
        nonisolated func updateTimeRange(_ newValue: Range<Date>) {
            Task { @MainActor in
                self.timeRange = newValue
            }
        }
    }
    
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @StandardActor private var standard: MyHeartCountsStandard
    @ObservationIgnored @Dependency(SensorKit.self) private var sensorKit
    @ObservationIgnored @Dependency(MHCBackgroundTasks.self) private var backgroundTasks
    @ObservationIgnored @Dependency(LocalNotifications.self) private var localNotifications
    // swiftlint:enable attributes
    
    /// The sensors that are currently being processed.
    @MainActor private(set) var activeActivities = Set<InProgressActivity>()

    /// The currently-running fetch & upload of SensorKit data, if any.
    @ObservationIgnored @MainActor private var activeFetch: SensorKitActiveFetch?


    nonisolated init() {}


    func configure() {
        guard SensorKit.isAvailable else {
            return
        }
        do {
            try backgroundTasks.register(.healthResearch(
                id: .sensorKitProcessing,
                options: [.requiresNetworkConnectivity, .requiresExternalPower],
                protectionTypeOfRequiredData: .complete
            ) { [weak self] in
                guard let self else {
                    return
                }
                guard !LaunchOptions.launchOptions[.disableSensorKitUpload] else {
                    return
                }
                guard await UIApplication.shared.isProtectedDataAvailable else {
                    throw SensorKitProcessingError.protectedDataUnavailable
                }
                if await standard.enableDebugSensorKitNotifications {
                    try? await self.localNotifications.send(title: "SensorKit Background Processing", body: "Task started")
                }
                try await fetchAndUploadNewData(.full)
                if await standard.enableDebugSensorKitNotifications {
                    try? await self.localNotifications.send(title: "SensorKit Background Processing", body: "Task ended")
                }
            })
        } catch {
            logger.error("Error registering SK background task: \(error)")
        }
    }


    func run() async {
        guard SensorKit.isAvailable else {
            return
        }
        do {
            // Wait a little bit to make sure all of the other setup stuff (esp Firebase!) has time to finish before we start uploading.
            try await Task.sleep(for: .seconds(1))
            for sensor in SensorKit.mhcSensors where sensor.authorizationStatus == .authorized {
                try Task.checkCancellation()
                try? await sensor.startRecording()
            }
            guard !LaunchOptions.launchOptions[.disableSensorKitUpload] else {
                return
            }
            let allowance = await DeviceBattery.workAllowance(
                lastRun: LocalPreferencesStore.standard[.lastSensorKitFetch],
                staleness: TimeConstants.day
            )
            guard allowance != .none else {
                return
            }
            try await fetchAndUploadNewData(allowance)
        } catch is CancellationError {} catch {
            logger.error("Failed to fetch and upload SensorKit data: \(error)")
        }
    }
    
    
    /// Does not await cancellation because SensorKit may leave a read suspended indefinitely.
    @MainActor
    func cancelAllActiveCollection() {
        guard let activeFetch else {
            return
        }
        activeFetch.task.cancel()
        if self.activeFetch?.task == activeFetch.task {
            self.activeFetch = nil
        }
    }


    @MainActor
    private func fetchAndUploadNewData(_ allowance: DeviceBattery.WorkAllowance) async throws {
        guard allowance != .none else {
            return
        }
        guard SensorKit.isAvailable else {
            return
        }
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw SensorKitProcessingError.protectedDataUnavailable
        }
        guard await standard.shouldCollectHealthData else {
            return
        }
        while true {
            let activeFetch: SensorKitActiveFetch
            if let existingFetch = self.activeFetch {
                activeFetch = existingFetch
            } else {
                let task = Task { @concurrent in
                    try await self._fetchAndUploadNewData(allowance)
                }
                activeFetch = SensorKitActiveFetch(task: task, allowance: allowance)
                self.activeFetch = activeFetch
            }
            defer {
                if self.activeFetch?.task == activeFetch.task {
                    self.activeFetch = nil
                }
            }
            try await withTaskCancellationHandler {
                try await activeFetch.task.value
            } onCancel: {
                activeFetch.task.cancel()
            }
            if allowance == .full && activeFetch.allowance == .limited {
                continue
            }
            return
        }
    }

    @concurrent
    private func _fetchAndUploadNewData(_ allowance: DeviceBattery.WorkAllowance) async throws {
        try Task.checkCancellation()
        let maximumBatchesPerSensor = allowance == .limited ? 1 : nil
        let concurrencyLimit = allowance == .limited ? 1 : (ProcessInfo.isProDevice ? 3 : 1)
        for definitions in SensorKit.mhcSensorUploadDefinitions.chunks(ofCount: concurrencyLimit) {
            try Task.checkCancellation()
            try await withThrowingDiscardingTaskGroup { taskGroup in
                for uploadDefinition in definitions {
                    taskGroup.addTask {
                        try await self.fetchAndUploadAnchored(
                            uploadDefinition,
                            maximumBatches: maximumBatchesPerSensor
                        )
                    }
                }
            }
        }
        try Task.checkCancellation()
        LocalPreferencesStore.standard[.lastSensorKitFetch] = .now
    }
    
    
    /// Publishes one fetched batch and advances its cursor as one indivisible step.
    ///
    /// The unstructured task deliberately does not inherit a background-task cancellation that may
    /// arrive after sidecar staging but before the Bundle and the cursor are durable.
    private func publishAndAcknowledge<Sample, Strategy: MHCSensorSampleUploadStrategy<Sample>>(
        _ batch: SensorKit.AnchoredBatch<Sample.SafeRepresentation>,
        uploadDefinition: MHCSensorUploadDefinition<Sample, Strategy>,
        to standard: MyHeartCountsStandard,
        activity: InProgressActivity
    ) async throws {
        let sensor = uploadDefinition.sensor
        let task = Task { @concurrent in
            let publication = try await standard.sensorKitBatchPublication(
                for: sensor,
                batchInfo: batch.info
            )
            try await uploadDefinition.strategy.upload(
                batch.samples,
                publication: publication,
                for: sensor,
                to: standard,
                activity: activity
            )
            try await batch.acknowledge()
            do {
                try await standard.completeSensorKitBatch(
                    publication.batchKey,
                    accountDataGeneration: publication.destination.accountDataGeneration
                )
            } catch {
                // The cursor is already durable. A transient local-ledger cleanup failure must not
                // make an acknowledged batch look unpublished or trigger a false retry.
                logger.error("Could not clean acknowledged SensorKit FHIR state: \(error)")
            }
        }
        try await task.value
    }


    /// Fetches all new SensorKit samples for the specified sensor (relative to the last time the function was called for the sensor), and uploads them all into the Firestore.
    @concurrent
    private func fetchAndUploadAnchored(
        _ uploadDefinition: some AnyMHCSensorUploadDefinition<some Any, some Any>,
        maximumBatches: Int?
    ) async throws {
        try Task.checkCancellation()
        guard SensorKit.isAvailable else {
            return
        }
        let uploadDefinition = MHCSensorUploadDefinition(uploadDefinition)
        let sensor = uploadDefinition.sensor
        guard sensorKit.authorizationStatus(for: sensor) == .authorized else {
            logger.notice("Skipping Sensor '\(sensor.displayName)' bc it's not authorized")
            return
        }
        logger.notice("Starting anchored fetch for SensorKit sensor '\(sensor.id)'")
        let activity = InProgressActivity(sensor: sensor)
        start(activity)
        defer {
            end(activity)
        }
        do {
            activity.updateMessage("Fetching Samples")
            var uploadedBatches = 0
            let standard = standard
            for try await batch in try await sensorKit.fetchAnchored(sensor) {
                activity.updateTimeRange(batch.info.timeRange)
                try await publishAndAcknowledge(
                    batch,
                    uploadDefinition: uploadDefinition,
                    to: standard,
                    activity: activity
                )
                uploadedBatches += 1
                if maximumBatches.map({ uploadedBatches >= $0 }) ?? false {
                    break
                }
                try Task.checkCancellation()
                guard await UIApplication.shared.isProtectedDataAvailable else {
                    throw SensorKitProcessingError.protectedDataUnavailable
                }
                activity.updateMessage("Fetching Samples")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SensorKitProcessingError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            logger.error("Failed to fetch & upload data for Sensor '\(sensor.displayName)': \(error)")
        }
        logger.notice("Anchored fetch for '\(sensor.id)' is complete.")
    }
    
    
    /// Fetches all SensorKit samples for the specified sensor, and uploads them all into the Firestore.
    ///
    /// Primarily intended for testing purposes.
    @concurrent
    func fetchAndUploadAllSamples(for uploadDefinition: some AnyMHCSensorUploadDefinition<some Any, some Any>) async throws {
        guard SensorKit.isAvailable else {
            return
        }
        let uploadDefinition = MHCSensorUploadDefinition(uploadDefinition)
        let sensor = uploadDefinition.sensor
        let activity = InProgressActivity(sensor: sensor)
        start(activity)
        defer {
            end(activity)
        }
        let fetcher = try await AnchoredFetcher(sensor: sensor) { _ in
            // we want to use ephemeral query anchors, bc this fetch is happening outside of the regular anchoring
            .ephemeral()
        }
        activity.updateMessage("Fetching Samples")
        for try await batch in fetcher {
            activity.updateTimeRange(batch.info.timeRange)
            try await publishAndAcknowledge(
                batch,
                uploadDefinition: uploadDefinition,
                to: standard,
                activity: activity
            )
            activity.updateMessage("Fetching Samples")
        }
    }
    
    /// Intended for debugging and development purposes
    func resetAllQueryAnchors() async {
        guard SensorKit.isAvailable else {
            return
        }
        func imp(_ sensor: some AnySensor) async {
            let sensor = Sensor(sensor)
            try? await sensorKit.resetQueryAnchors(for: sensor)
        }
        for sensor in SensorKit.allKnownSensors {
            await imp(sensor)
        }
    }
    
    nonisolated private func start(_ activity: InProgressActivity) {
        Task { @MainActor in
            activeActivities.insert(activity)
        }
    }
    
    nonisolated private func end(_ activity: InProgressActivity) {
        Task { @MainActor in
            activeActivities.remove(activity)
        }
    }
}


extension MHCBackgroundTasks.TaskIdentifier {
    static let sensorKitProcessing = Self("edu.stanford.MyHeartCounts.SensorKitProcessing")
}


extension LocalPreferenceKeys {
    /// The last time a SensorKit fetch was performed.
    static let lastSensorKitFetch = LocalPreferenceKey<Date?>("lastSensorKitFetch")
}


// MARK: Sensors

extension SensorKit {
    /// All sensors we want to enable automatic data collection for.
    ///
    /// - Note: The elements here are ordered roughly based on the expected number of samples and/or processing cost, in increasing order.
    static let mhcSensorUploadDefinitions: [any AnyMHCSensorUploadDefinition] = {
        guard SensorKit.isAvailable else {
            return []
        }
        return [
            MHCSensorUploadDefinition(sensor: .visits, strategy: UploadStrategyStructured()),
            MHCSensorUploadDefinition(sensor: .onWrist, strategy: UploadStrategyStructured()),
            MHCSensorUploadDefinition(sensor: .deviceUsage, strategy: UploadStrategyStructured()),
            MHCSensorUploadDefinition(sensor: .ecg, strategy: UploadStrategyECG()),
            MHCSensorUploadDefinition(sensor: .wristTemperature, strategy: UploadStrategyWristTemperature()),
            MHCSensorUploadDefinition(sensor: .heartRate, strategy: UploadStrategyCSVFile()),
            MHCSensorUploadDefinition(sensor: .pedometer, strategy: UploadStrategyCSVFile()),
            
            MHCSensorUploadDefinition(sensor: .ambientLight, strategy: UploadStrategyCSVFile()),
            MHCSensorUploadDefinition(sensor: .accelerometer, strategy: UploadStrategyCSVFile()),
            MHCSensorUploadDefinition(sensor: .ambientPressure, strategy: UploadStrategyCSVFile()),
            MHCSensorUploadDefinition(sensor: .ppg, strategy: SRPhotoplethysmogramSample.UploadStrategy())
        ]
    }()
    
    static let mhcSensors: [any AnySensor] = mhcSensorUploadDefinitions.map { $0.typeErasedSensor }
}


extension ManagedFileUpload.Category {
    init(_ sensor: any AnySensor) {
        self.init(id: "SensorKitUpload/\(sensor.id)", title: "SensorKit \(sensor.displayName)", firebasePath: "SensorKit/\(sensor.id)")
    }

    func remotePath(for filename: String) -> String {
        "\(firebasePath)/\(filename)"
    }
}
