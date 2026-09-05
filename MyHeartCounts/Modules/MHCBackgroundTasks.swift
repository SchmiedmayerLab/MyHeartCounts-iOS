//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API

import BackgroundTasks
import Foundation
import OSLog
import Spezi
import SpeziFoundation
import SwiftUI
import Synchronization


final class MHCBackgroundTasks: Module, EnvironmentAccessible, @unchecked Sendable {
    private enum TaskHandlingError: Error {
        /// A task with this id is already registered with the ``MHCBackgroundTasks`` module.
        case alreadyRegistered
        /// The ``MHCBackgroundTasks`` module was unable to find a ``MHCBackgroundTasks/TaskDefinition`` for this identifier.
        case missingTaskRegistration
        /// Attempted to register a ``MHCBackgroundTasks/TaskDefinition`` whose identifier is not in the `Info.plist`'s list of permitted task identifiers.
        case invalidTaskIdentifier
        /// The app's launch sequence has already completed, and no further tasks can be registered.
        case tooLateForRegistration
    }
    
    // swiftlint:disable attributes
    @Application(\.logger) private var logger
    @Dependency(Lifecycle.self) private var lifecycle
    @Dependency(LocalNotifications.self) private var localNotifications
    // swiftlint:enable attributes
    
    private let registeredTasks = Mutex<[TaskIdentifier: TaskDefinition]>([:])

    @concurrent
    static func execute(
        handler: @escaping TaskDefinition.Handler,
        completion: @escaping @Sendable (Result<Void, any Error>) async -> Void,
        reschedule: @escaping @Sendable () -> Void
    ) async {
        let result: Result<Void, any Error>
        do {
            try Task.checkCancellation()
            try await handler()
            try Task.checkCancellation()
            result = .success(())
        } catch {
            result = .failure(error)
        }
        reschedule()
        await completion(result)
    }

    func configure() {
        lifecycle.onChange(of: \.scenePhase) { _, newValue in
            if newValue == .background {
                let taskIds = self.registeredTasks.withLock { Array($0.keys) }
                for taskId in taskIds {
                    do {
                        try self.schedule(taskId)
                        self.logger.notice("Scheduled task '\(taskId)'")
                    } catch {
                        self.logger.error("Failed scheduling task '\(taskId)': \(error)")
                    }
                }
            }
        }
    }
    
    func register(_ definition: TaskDefinition) throws {
        // The `BGTaskScheduler` docs state that "Registration of all launch handlers must be complete before the end of
        // `applicationDidFinishLaunching(_:)`". On iOS 18, registering later reliably crashes the app (an `NSInternalInconsistencyException`
        // that no Swift `catch` can see); iOS 26.4+ silently accepts it. Since the docs still state the requirement, we enforce it everywhere.
        //
        // This matters because the Firebase-dependent modules are deferred-loaded: on the launch during which the user picks a region,
        // they get configured well after the launch sequence completed, so their registrations would be exactly the too-late kind.
        // Rejecting them is safe. `lastUsedFirebaseConfig` is set from then on, so every subsequent launch — foreground or background —
        // loads these modules as part of the launch sequence, registers their tasks during `willFinishLaunching`, and submits them
        // the first time the scene phase becomes `.background` (which, via `Lifecycle`'s `initial: true` tracking, also happens on
        // background launches). The only cost is that these tasks stay unregistered for the rest of the one session in which the
        // region was picked.
        let canRegister = !MyHeartCountsDelegate.didFinishLaunching
        guard canRegister else {
            throw TaskHandlingError.tooLateForRegistration
        }
        try registeredTasks.withLock { registeredTasks in // swiftlint:disable:this closure_body_length
            guard !registeredTasks.keys.contains(definition.id) else {
                throw TaskHandlingError.alreadyRegistered
            }
            let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: definition.id.rawValue, using: nil) { task in
                let asyncTask = Task { @concurrent in
                    await self.track(.start, for: definition.id)
                    await Self.execute(
                        handler: definition.handler,
                        completion: { result in
                            switch result {
                            case .success:
                                await self.track(.succeeded, for: definition.id)
                                task.setTaskCompleted(success: true)
                            case .failure(let error):
                                await self.track(.failed(error: "\(error)"), for: definition.id)
                                task.setTaskCompleted(success: false)
                            }
                        },
                        reschedule: {
                            do {
                                try self.schedule(definition.id)
                            } catch {
                                self.logger.error("Failed rescheduling task '\(definition.id)': \(error)")
                            }
                        }
                    )
                }
                task.expirationHandler = {
                    Task {
                        await self.track(.expiration, for: definition.id)
                    }
                    asyncTask.cancel()
                }
            }
            if didRegister {
                logger.notice("Registered background task with id '\(definition.id)'")
                registeredTasks[definition.id] = definition
            } else {
                throw TaskHandlingError.invalidTaskIdentifier
            }
        }
    }
    
    func schedule(_ taskId: TaskIdentifier) throws {
        try registeredTasks.withLock { registeredTasks in
            guard let definition = registeredTasks[taskId] else {
                throw TaskHandlingError.missingTaskRegistration
            }
            try BGTaskScheduler.shared.submit(definition.makeRequest())
        }
    }
    
    
    /// - Important: Only intended for use during local development (and potentially TestFlight deployments, if that's allowed)
    func trigger(_ taskId: TaskIdentifier) {
        let sel = Selector(("_simulateLaunchForTaskWithIdentifier:"))
        BGTaskScheduler.shared.perform(sel, with: taskId.rawValue as NSString) // swiftlint:disable:this legacy_objc_type
    }
}


extension MHCBackgroundTasks {
    struct TaskIdentifier: Hashable, CustomStringConvertible, Codable, Sendable {
        let rawValue: String
        var description: String { rawValue }
        
        init(_ rawValue: String) {
            self.rawValue = rawValue
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(String.self)
        }
        
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
    
    
    struct TaskDefinition: Identifiable, Sendable {
        typealias Handler = @Sendable () async throws -> Void
        
        struct NextTriggerDate {
            static var earliestPossible: Self {
                Self { _ in nil }
            }

            private let resolveDate: @Sendable (Date) -> Date?

            private init(resolveDate: @escaping @Sendable (Date) -> Date?) {
                self.resolveDate = resolveDate
            }
            
            static func absolute(_ date: Date) -> Self {
                Self { _ in date }
            }
            static func after(_ timeInterval: TimeInterval) -> Self {
                Self { $0.addingTimeInterval(timeInterval) }
            }
            static func next(_ components: DateComponents) -> Self {
                Self {
                    Calendar.current.nextDate(after: $0, matching: components, matchingPolicy: .nextTime)
                }
            }
            static func next(_ rule: Calendar.RecurrenceRule) -> Self {
                Self { date in
                    rule.recurrences(of: date).first { _ in true }
                }
            }

            func resolve(relativeTo date: Date = .now) -> Date? {
                resolveDate(date)
            }
        }
        
        struct ProcessingTaskOptions: OptionSet {
            static let requiresExternalPower = Self(rawValue: 1 << 0)
            static let requiresNetworkConnectivity = Self(rawValue: 1 << 1)
            let rawValue: UInt8
        }
        
        let id: TaskIdentifier
        fileprivate let handler: Handler
        fileprivate let makeRequest: @Sendable () -> BGTaskRequest
        
        static func appRefresh(
            id: TaskIdentifier,
            nextTriggerDate: NextTriggerDate = .earliestPossible,
            handler: @escaping Handler
        ) -> Self {
            Self(id: id, handler: handler) {
                let request = BGAppRefreshTaskRequest(identifier: id.rawValue)
                request.earliestBeginDate = nextTriggerDate.resolve()
                return request
            }
        }
        
        static func processing(
            id: TaskIdentifier,
            nextTriggerDate: NextTriggerDate = .earliestPossible,
            options: ProcessingTaskOptions = [],
            handler: @escaping Handler
        ) -> Self {
            Self(id: id, handler: handler) {
                let request = BGProcessingTaskRequest(identifier: id.rawValue)
                request.earliestBeginDate = nextTriggerDate.resolve()
                if options.contains(.requiresExternalPower) {
                    request.requiresExternalPower = true
                }
                if options.contains(.requiresNetworkConnectivity) {
                    request.requiresNetworkConnectivity = true
                }
                return request
            }
        }
        
        static func healthResearch(
            id: TaskIdentifier,
            nextTriggerDate: NextTriggerDate = .earliestPossible,
            options: ProcessingTaskOptions = [],
            protectionTypeOfRequiredData: FileProtectionType = .completeUntilFirstUserAuthentication,
            handler: @escaping Handler
        ) -> Self {
            Self(id: id, handler: handler) {
                let request = BGHealthResearchTaskRequest(identifier: id.rawValue)
                request.earliestBeginDate = nextTriggerDate.resolve()
                if options.contains(.requiresExternalPower) {
                    request.requiresExternalPower = true
                }
                if options.contains(.requiresNetworkConnectivity) {
                    request.requiresNetworkConnectivity = true
                }
                // swiftlint:disable:next legacy_objc_type
                request.protectionTypeOfRequiredData = protectionTypeOfRequiredData.rawValue as NSString
                return request
            }
        }
    }
}


extension BGTask: @retroactive @unchecked Sendable {}


// MARK: Tracking

extension MHCBackgroundTasks {
    struct Event: Hashable, Codable {
        enum Kind: Hashable, Codable, RawRepresentable<String> {
            case start
            case succeeded
            case failed(error: String)
            case expiration
            
            var rawValue: String {
                switch self {
                case .start:
                    "start"
                case .succeeded:
                    "succeeded"
                case .failed(let error):
                    "failed(\(error))"
                case .expiration:
                    "expired"
                }
            }
            
            init?(rawValue: String) {
                switch rawValue {
                case "start":
                    self = .start
                case "succeeded", "stop": // we (incorrectly) parse all past `"stop"` results as successes.
                    self = .succeeded
                case "expired", "expiration":
                    self = .expiration
                default:
                    guard rawValue.starts(with: "failed("), rawValue.ends(with: ")") else {
                        return nil
                    }
                    let errorMsg = rawValue.dropFirst("failed(".count).dropLast()
                    self = .failed(error: String(errorMsg))
                }
            }
            
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                let rawValue = try container.decode(String.self)
                if let value = Self(rawValue: rawValue) {
                    self = value
                } else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid rawValue '\(rawValue)'"))
                }
            }
            
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }
        
        let date: Date
        let taskId: MHCBackgroundTasks.TaskIdentifier
        let kind: Kind
    }
    
    private func track(_ kind: Event.Kind, for taskId: TaskIdentifier) async {
        let prefs = LocalPreferencesStore.standard
        prefs[.backgroundTaskEvents].append(.init(date: .now, taskId: taskId, kind: kind))
        if prefs[.backgroundTaskNotifications] {
            let event: String = switch kind {
            case .start:
                "start"
            case .succeeded:
                "success"
            case .failed(let error):
                "failed: \(error)"
            case .expiration:
                "expiration"
            }
            try? await localNotifications.send(
                title: "[dbg] background task \(taskId)",
                body: "\(event) at \(Date.now)"
            )
        }
    }
}
