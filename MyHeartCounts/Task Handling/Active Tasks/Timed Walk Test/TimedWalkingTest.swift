//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable type_contents_order

import ActivityKit
import CoreHaptics
import CoreMotion
import Foundation
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziFoundation
import SpeziLocalStorage
import SpeziStudyDefinition
import SwiftUI


@Observable
@MainActor
final class TimedWalkingTest: Module, EnvironmentAccessible, Sendable {
    private typealias LiveActivity = Activity<TimedWalkTestLiveActivityAttributes>
    
    enum State: Hashable, Sendable {
        case idle
        case testActive(ActiveSession)
        
        var isActive: Bool {
            switch self {
            case .testActive: true
            case .idle: false
            }
        }
    }
    
    @Observable
    @MainActor
    final class ActiveSession: nonisolated Hashable, nonisolated Identifiable, Sendable {
        let isRecoveredTest: Bool
        private(set) var inProgressResult: TimedWalkingTestResult
        /// The `Task` that waits for the session's duration to pass, and then ends the session
        fileprivate var completeSessionTask: Task<TimedWalkingTestResult?, any Error>?
        
        var startDate: Date {
            inProgressResult.startDate
        }
        
        nonisolated var id: some Hashable {
            ObjectIdentifier(self)
        }
        
        init(inProgressResult: TimedWalkingTestResult, isRecoveredTest: Bool) {
            self.isRecoveredTest = isRecoveredTest
            self.inProgressResult = inProgressResult
        }
        
        nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }
        
        nonisolated static func == (lhs: ActiveSession, rhs: ActiveSession) -> Bool {
            ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
        }
    }
    
    enum TestError: Error, LocalizedError {
        enum StartFailureReason {
            case missingSensorPermissions
            case alreadyActive
        }
        
        case unableToStart(StartFailureReason)
        case cancelled
        case other(any Error)
        
        // periphery:ignore - API
        var errorDescription: LocalizedStringResource? {
            switch self {
            case .unableToStart(.alreadyActive):
                "Another test is already active"
            case .unableToStart(.missingSensorPermissions):
                "There are missing Motion Sensor permissions"
            case .cancelled:
                "The test was cancelled"
            case .other(let error):
                "\(String(describing: error))"
            }
        }
    }
    
    /// Whether the ``TimedWalkingTest`` module should use Live Activities.
    ///
    /// Currently disabled for the time being, because of difficulties dismissing the activities.
    static let enableLiveActivities: Bool = true
    
    // swiftlint:disable attributes
    @ObservationIgnored @StandardActor private var standard: MyHeartCountsStandard
    @ObservationIgnored @Dependency(WatchConnection.self) private var watchManager
    @ObservationIgnored @Dependency(LocalStorage.self) private var localStorage
    @ObservationIgnored @Dependency(Lifecycle.self) private var lifecycle
    // swiftlint:enable attributes
    
    private let hapticEngine = try? CHHapticEngine()
    nonisolated(unsafe) private let pedometer = CMPedometer()
    nonisolated(unsafe) private let altimeter = CMAltimeter()
    
    private(set) var state: State = .idle
    
    /// The most recent Timed Walking Test result
    private(set) var mostRecentResult: TimedWalkingTestResult?
    
    private(set) var absoluteAltitudeMeasurements: [AbsoluteAltitudeMeasurement] = []
    private(set) var relativeAltitudeMeasurements: [RelativeAltitudeMeasurement] = []
    private(set) var pedometerMeasurements: [PedometerData] = []
    private(set) var pedometerEvents: [PedometerEvent] = []
    
    
    func configure() {
        if let inProgressTest = try? localStorage.load(.inProgressTimedWalkTest) {
            try? localStorage.delete(.inProgressTimedWalkTest)
            Task {
                try await recover(inProgressTest)
            }
        }
        lifecycle.onChange(of: \.scenePhase, initial: true) { _, scenePhase in
            switch scenePhase {
            case .active:
                // the app just was opened. clear out any expired live activities managed by the TimedWalkTest module
                Task {
                    for activity in LiveActivity.activities.filter({ activity in
                        switch activity.content.state {
                        case .completed:
                            true
                        case .ongoing(startDate: _, let endDate):
                            endDate >= .now
                        }
                    }) {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                }
            case .background, .inactive:
                break
            @unknown default:
                break
            }
        }
    }
    
    func start(_ test: TimedWalkingTestConfiguration) async throws(TestError) -> TimedWalkingTestResult? {
        let startDate = Date.now
        return try await start(
            inProgressTest: TimedWalkingTestResult(
                id: UUID(),
                test: test,
                startDate: startDate,
                endDate: startDate.addingTimeInterval(test.duration.timeInterval),
                numberOfSteps: 0,
                distanceCovered: 0
            ),
            isRecoveredTest: false
        )
    }
    
    
    private func start(inProgressTest: TimedWalkingTestResult, isRecoveredTest: Bool) async throws(TestError) -> TimedWalkingTestResult? {
        switch state {
        case .idle:
            break
        case .testActive:
            throw .unableToStart(.alreadyActive)
        }
        guard await CMMotionManager.requestMotionDataAccess() else {
            throw .unableToStart(.missingSensorPermissions)
        }
        do {
            try await watchManager.startWorkoutOnWatch(for: inProgressTest.test)
            logger.notice("Successfully launched watch app")
        } catch {
            // we still continue if the watch app failed to launch.
            logger.notice("Failed to launch watch app: \(error)")
        }
        let startInstant = ContinuousClock.Instant.now
        let session = ActiveSession(inProgressResult: inProgressTest, isRecoveredTest: isRecoveredTest)
        state = .testActive(session)
        startPhoneSensorDataCollection(for: session)
        let sessionTask = Task {
            #if targetEnvironment(simulator)
            // Enable a simple testing of the UI on the simulator.
            try await Task.sleep(until: startInstant.advanced(by: Duration.seconds(10)))
            #else
            try await Task.sleep(until: startInstant.advanced(by: inProgressTest.test.duration))
            #endif
            return try await stop()
        }
        session.completeSessionTask = sessionTask
        Task {
            try? localStorage.store(session.inProgressResult, for: .inProgressTimedWalkTest)
            _ = await startLiveActivity(for: inProgressTest)
        }
        let result = await sessionTask.result
        switch result {
        case .success(let result):
            return result
        case .failure(let error):
            throw error is CancellationError ? .cancelled : .other(error)
        }
    }
    
    
    private func recover(_ inProgressTest: TimedWalkingTestResult) async throws {
        let isStillOngoing = inProgressTest.endDate > .now
        if isStillOngoing {
            // the test is still ongoing, so we need to
            _ = try await start(inProgressTest: inProgressTest, isRecoveredTest: true)
        } else {
            // the test has already ended, but wasn't finalized at the time
            // (ie, the app was terminated while the test was still running)
            _ = try await stop(inProgressTest: inProgressTest, isRecoveredTest: true)
        }
    }
    
    
    func stop(discardResult: Bool = false) async throws -> TimedWalkingTestResult? {
        switch state {
        case .idle:
            return nil
        case .testActive(let session):
            try? localStorage.delete(.inProgressTimedWalkTest)
            defer {
                state = .idle
            }
            var result = session.inProgressResult
            session.completeSessionTask?.cancel()
            stopPhoneSensorDataCollection()
            if !discardResult {
                try? vibrate()
            }
            result = try await stop(inProgressTest: result, isRecoveredTest: false)
            if !discardResult {
                try? await standard.uploadHealthObservation(result)
                return result
            } else {
                return nil
            }
        }
    }
    
    
    /// Stops an in-progress test.
    ///
    /// - returns: The actual result of the test.
    ///
    /// - Note: this function will unconditonally stop the test, even if it us still ongoing and not supposed to end until at some future point in time.
    private func stop(inProgressTest result: TimedWalkingTestResult, isRecoveredTest: Bool) async throws -> TimedWalkingTestResult {
        var result = result
        if ProcessInfo.isRunningInSimulator {
            result.numberOfSteps = 624
            result.distanceCovered = 842
        } else {
            result = try await withCheckedThrowingContinuation { [result] continuation in
                pedometer.queryPedometerData(from: result.startDate, to: result.endDate) { @Sendable [result] data, error in
                    var result = result
                    guard let data else {
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: result) // hmmm
                        }
                        return
                    }
                    result.numberOfSteps = data.numberOfSteps.intValue
                    result.distanceCovered = data.distance?.doubleValue ?? 0
                    continuation.resume(returning: result)
                }
            }
        }
        if isRecoveredTest || lifecycle.scenePhase == .active {
            // if we're stopping/finalizing a recovered test or we're in the foreground, we want to immediately remove the live activity
            for activity in LiveActivity.activities where activity.attributes.testRunId == result.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        } else {
            // if we're stopping a non-recovered test, or the app is currently running in the background,
            // we want the live activity to display a "done!" message for a bit, and then dismiss it after a while.
            if let liveActivity = LiveActivity.activities.first(where: { $0.attributes.testRunId == result.id }) {
                nonisolated(unsafe) let liveActivity = liveActivity
                await liveActivity.update(.init(
                    state: .completed(
                        numSteps: result.numberOfSteps,
                        distance: Measurement(value: result.distanceCovered, unit: .meters)
                    ),
                    staleDate: .now.addingTimeInterval(30)
                ))
                Task {
                    try await Task.sleep(for: .seconds(30))
                    await liveActivity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        return result
    }
}


extension TimedWalkingTest {
    private func vibrate() throws {
        guard let engine = hapticEngine else {
            return
        }
        let tapDuration: TimeInterval = 0.15
        let pattern = try CHHapticPattern(
            events: (0..<5).map { idx in
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1)
                    ],
                    relativeTime: TimeInterval(idx) * tapDuration * 2,
                    duration: tapDuration
                )
            },
            parameters: []
        )
        let player = try engine.makePlayer(with: pattern)
        _Concurrency.Task {
            try await engine.start()
            try player.start(atTime: 0)
        }
    }
}


extension TimedWalkingTest {
    private func startPhoneSensorDataCollection(for session: ActiveSession) {
        let queue = OperationQueue()
        absoluteAltitudeMeasurements.removeAll(keepingCapacity: true)
        altimeter.startAbsoluteAltitudeUpdates(to: queue) { @Sendable (data: CMAbsoluteAltitudeData?, _) in
            guard let data else {
                return
            }
            let measurement = AbsoluteAltitudeMeasurement(data)
            Task { @MainActor in
                self.absoluteAltitudeMeasurements.append(measurement)
            }
        }
        relativeAltitudeMeasurements.removeAll(keepingCapacity: true)
        altimeter.startRelativeAltitudeUpdates(to: queue) { @Sendable (data: CMAltitudeData?, _) in
            guard let data else {
                return
            }
            let measurement = RelativeAltitudeMeasurement(data)
            Task { @MainActor in
                self.relativeAltitudeMeasurements.append(measurement)
            }
        }
        pedometerMeasurements.removeAll(keepingCapacity: true)
        pedometer.startUpdates(from: session.startDate) { @Sendable (data: CMPedometerData?, _) in
            guard let data else {
                return
            }
            let measurement = PedometerData(data)
            Task { @MainActor in
                self.pedometerMeasurements.append(measurement)
            }
        }
        pedometerEvents.removeAll(keepingCapacity: true)
        pedometer.startEventUpdates { @Sendable (event: CMPedometerEvent?, _) in
            guard let event else {
                return
            }
            let trackedEvent = PedometerEvent(event)
            Task { @MainActor in
                self.pedometerEvents.append(trackedEvent)
            }
        }
    }
    
    private func stopPhoneSensorDataCollection() {
        altimeter.stopAbsoluteAltitudeUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        pedometer.stopEventUpdates()
    }
}


extension TimedWalkingTest {
    @discardableResult
    private func startLiveActivity(for test: TimedWalkingTestResult) async -> LiveActivity? {
        guard Self.enableLiveActivities else {
            return nil
        }
        guard test.endDate > .now else {
            return nil
        }
        for activity in Activity<TimedWalkTestLiveActivityAttributes>.activities {
            await activity.end(nil)
        }
        let attributes = TimedWalkTestLiveActivityAttributes(
            testRunId: test.id,
            test: test.test
        )
        let contentState = TimedWalkTestLiveActivityAttributes.ContentState.ongoing(
            startDate: test.startDate,
            endDate: test.endDate
        )
        return try? Activity<TimedWalkTestLiveActivityAttributes>.request(
            attributes: attributes,
            content: .init(state: contentState, staleDate: test.endDate),
            pushType: nil
        )
    }
    
    static func endLiveActivity() async {
        for activity in Activity<TimedWalkTestLiveActivityAttributes>.activities {
            await activity.end(nil)
        }
    }
}


// MARK: Permission Handling

extension CMMotionManager {
    static func authorizationStatus() -> CMAuthorizationStatus {
        CMPedometer.authorizationStatus()
    }
    
    /// Requests access to the "Motion and Fitness" data.
    ///
    /// If the user has already granted or denied access in the past, or access is otherwise impossible, this function returns immediately.
    /// Otherwise (i.e., if the user hasn't been asked yet), it will prompt the user to grant access and return then.
    ///
    /// - returns: A boolean indicating whether the request was successful and we now have access.
    static func requestMotionDataAccess() async -> Bool {
        // we're using the pedometer here, but it doesn't really matter since requesting access to that will also give us access to the other Motion sensors (eg: altimeter)
        switch CMPedometer.authorizationStatus() {
        case .authorized:
            true
        case .denied, .restricted:
            false
        case .notDetermined:
            await withCheckedContinuation { continuation in
                // ISSUE: we use the `queryPedometerData` function to trigger the permission prompt.
                // But: The completion handler will only get called if the pedometer object is still
                // around by the time the user grants/denies us the permission.
                // Meaning that we need to somehow extend the lifetime of the pedometer object.
                // We do this by capturing it in the closure, and then setting it to nil once we've received the callback.
                nonisolated(unsafe) var pedometer: CMPedometer? = CMPedometer()
                pedometer!.queryPedometerData(from: .now, to: .now) { @Sendable _, error in // swiftlint:disable:this force_unwrapping
                    // we simply assume that the absence of an error implies that the authorization was successfully granted
                    continuation.resume(returning: error == nil || CMMotionManager.authorizationStatus() == .authorized)
                    pedometer = nil
                }
            }
        @unknown default:
            false
        }
    }
}


// MARK: Persistence

extension LocalStorageKeys {
    static let inProgressTimedWalkTest = LocalStorageKey<TimedWalkingTestResult>(
        "edu.stanford.MyHeartCounts.inProgressTimedWalkTest",
        setting: .unencrypted(excludeFromBackup: true)
    )
}
