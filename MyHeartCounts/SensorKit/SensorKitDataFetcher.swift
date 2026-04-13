//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziFoundation
import SpeziSensorKit


@Observable
final class SensorKitDataFetcher: ServiceModule, EnvironmentAccessible, @unchecked Sendable {
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
    
    /// The task that is fetching and uploading the SensorKit data.
    @ObservationIgnored @MainActor private var processingTask: Task<Void, Never>?
    
    
    nonisolated init() {}
    
    
    func configure() {
        guard SensorKit.isAvailable else {
            return
        }
        do {
            try backgroundTasks.register(.healthResearch(
                id: .sensorKitProcessing,
                options: [.requiresNetworkConnectivity],
                protectionTypeOfRequiredData: .complete
            ) { [weak self] in
                guard let self else {
                    return
                }
                guard !LaunchOptions.launchOptions[.disableSensorKitUpload] else {
                    return
                }
                if await standard.enableDebugSensorKitNotifications {
                    try? await self.localNotifications.send(title: "SensorKit Background Processing", body: "Task started")
                }
                // it could be that the `run()` function already ran before the background task was triggered;
                // in this case this call won't start a second, parallel fetch, but instead will simply wait for
                // the already-active fetch to complete.
                await fetchAndUploadNewData()
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
        Task(priority: .background) {
            // wait a little bit to make sure all of the other setup stuff (esp Firebase!) has time to finish before we start uploading
            try await Task.sleep(for: .seconds(1))
            for sensor in SensorKit.mhcSensors where sensor.authorizationStatus == .authorized {
                try? await sensor.startRecording()
            }
            if !LaunchOptions.launchOptions[.disableSensorKitUpload] {
                await fetchAndUploadNewData()
            }
        }
    }
    
    // periphery:ignore - API
    @MainActor
    func cancelAllActiveCollection() {
        processingTask?.cancel()
        processingTask = nil
    }
    
    
    @MainActor
    private func fetchAndUploadNewData() async {
        guard SensorKit.isAvailable else {
            return
        }
        guard await standard.shouldCollectHealthData else {
            return
        }
        if let processingTask {
            // if we're already performing this task, we simply wait on that task's result, instead of starting a competing second one.
            // this is in order to properly support background processing/fetches.
            _ = await processingTask.result
        } else {
            let task = Task { @concurrent in
                await withManagedTaskQueue(limit: ProcessInfo.isProDevice ? 3 : 1) { taskQueue in
                    for uploadDefinition in SensorKit.mhcSensorUploadDefinitions {
                        taskQueue.addTask {
                            await self.fetchAndUploadAnchored(uploadDefinition)
                        }
                    }
                }
            }
            processingTask = task
            _ = await task.result
        }
    }
    
    
    /// Fetches all new SensorKit samples for the specified sensor (relative to the last time the function was called for the sensor), and uploads them all into the Firestore.
    @concurrent
    private func fetchAndUploadAnchored(_ uploadDefinition: some AnyMHCSensorUploadDefinition<some Any, some Any>) async {
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
            for try await (batchInfo, batch) in try await sensorKit.fetchAnchored(sensor) {
                activity.updateTimeRange(batchInfo.timeRange)
                try await uploadDefinition.strategy.upload(consume batch, batchInfo: batchInfo, for: sensor, to: standard, activity: activity)
                activity.updateMessage("Fetching Samples")
            }
        } catch {
            logger.error("Failed to fetch & upload data for Sensor '\(sensor.displayName)': \(error)")
        }
        logger.notice("Anchored fetch for '\(sensor.id)' is complete.")
    }
    
    // periphery:ignore
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
        for try await (batchInfo, samples) in fetcher {
            activity.updateTimeRange(batchInfo.timeRange)
            try await uploadDefinition.strategy.upload(consume samples, batchInfo: batchInfo, for: sensor, to: standard, activity: activity)
            activity.updateMessage("Fetching Samples")
        }
    }
    
    /// Intended for debugging and development purposes
    func resetAllQueryAnchors() {
        guard SensorKit.isAvailable else {
            return
        }
        func imp(_ sensor: some AnySensor) {
            let sensor = Sensor(sensor)
            try? sensorKit.resetQueryAnchors(for: sensor)
        }
        for sensor in SensorKit.allKnownSensors {
            imp(sensor)
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
            MHCSensorUploadDefinition(sensor: .visits, strategy: UploadStrategyFHIRObservations()),
            MHCSensorUploadDefinition(sensor: .onWrist, strategy: UploadStrategyFHIRObservations()),
            MHCSensorUploadDefinition(sensor: .deviceUsage, strategy: UploadStrategyFHIRObservations()),
            MHCSensorUploadDefinition(sensor: .ecg, strategy: UploadStrategyFHIRObservations()),
            MHCSensorUploadDefinition(sensor: .wristTemperature, strategy: UploadStrategyCSVFile2()),
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
}
