//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveHealthKit
import GroveStudyDefinition
import HealthKit
import WatchKit


@Observable
@MainActor
final class WorkoutManager: NSObject, Module, EnvironmentAccessible, HKWorkoutSessionDelegate {
    private enum WorkoutSessionError: Error {
        case alreadyAWorkoutOngoing
    }
    
    enum State: Hashable, Sendable {
        case idle
        case active(timeRange: Range<Date>)
    }
    
    @ObservationIgnored @Dependency(HealthKit.self) private var healthKit // swiftlint:disable:this attributes
    
    private var workoutSession: HKWorkoutSession?
    
    private var currentSessionExpectedTimeRange: Range<Date>?
    private(set) var state: State = .idle
    
    
    private func updateState() {
        guard let workoutSession else {
            state = .idle
            return
        }
        switch workoutSession.state {
        case .notStarted, .prepared:
            state = .idle
        case .running, .paused:
            if let currentSessionExpectedTimeRange {
                state = .active(timeRange: currentSessionExpectedTimeRange)
            }
        case .ended:
            state = .idle
        case .stopped:
            state = .idle
        @unknown default:
            if let currentSessionExpectedTimeRange {
                state = .active(timeRange: currentSessionExpectedTimeRange)
            } else {
                state = .idle
            }
        }
    }
    
    
    func startWorkout(for test: TimedWalkingTestConfiguration, timeRange: Range<Date>) async throws {
        guard workoutSession == nil else {
            throw WorkoutSessionError.alreadyAWorkoutOngoing
        }
        try await healthKit.askForAuthorization()
        let configuration = HKWorkoutConfiguration()
        switch test.kind {
        case .walking:
            configuration.activityType = .walking
        case .running:
            configuration.activityType = .running
        }
        // does this matter? do we want to somehow ask the user / try to figure it out?
        // the iPhone (and probably also the watch) do know whether they're indoors/outdoors, so we might be able to access that information?
        // maybe setting it to unknown results in the system doing this for us?
        configuration.locationType = .unknown
        
        let workoutSession = try HKWorkoutSession(
            healthStore: healthKit.healthStore,
            configuration: configuration
        )
        workoutSession.delegate = self
        self.workoutSession = workoutSession
        self.currentSessionExpectedTimeRange = timeRange
        
        let builder = workoutSession.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthKit.healthStore, workoutConfiguration: configuration)
//        builder.delegate = self // ?? (do we care?)
        
        workoutSession.startActivity(with: .now)
        try await builder.beginCollection(at: .now)
        
        Task {
            try await Task.sleep(for: .seconds(timeRange.upperBound.timeIntervalSince(timeRange.lowerBound)))
            try? await stopWorkout()
        }
    }
    
    
    func stopWorkout() async throws {
        guard let workoutSession else {
            return
        }
        let builder = workoutSession.associatedWorkoutBuilder()
        try await builder.endCollection(at: .now)
        try await builder.finishWorkout()
        workoutSession.stopActivity(with: .now)
        self.currentSessionExpectedTimeRange = nil
        // NOTE: we're intentionally not setting self.workoutSession to nil in here, but instead do it in the delegate below.
    }
    
    
    // MARK: HKWorkoutSessionDelegate
    
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            if toState == .stopped {
                self.workoutSession = nil
            }
            updateState()
        }
        if (fromState != .running && toState == .running) || (fromState == .running && (toState == .stopped || toState == .ended)) {
            WKInterfaceDevice.current().play(.success)
        }
    }
    
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in
            updateState()
            self.workoutSession = nil
        }
    }
}
