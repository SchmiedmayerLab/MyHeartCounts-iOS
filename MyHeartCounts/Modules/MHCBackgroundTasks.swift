//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
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
    }
    
    @Application(\.logger)
    private var logger
    
    @Dependency(Lifecycle.self)
    private var lifecycle
    
    private let registeredTasks = Mutex<[TaskIdentifier: TaskDefinition]>([:])
    
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
        try registeredTasks.withLock { registeredTasks in
            guard !registeredTasks.keys.contains(definition.id) else {
                throw TaskHandlingError.alreadyRegistered
            }
            let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: definition.id.rawValue, using: nil) { task in
                let asyncTask = Task {
                    defer {
                        Task {
                            try? self.schedule(definition.id)
                        }
                    }
                    do {
                        MHCBackgroundTasks.track(.start, for: definition.id)
                        try await definition.handler()
                        MHCBackgroundTasks.track(.stop, for: definition.id)
                        task.setTaskCompleted(success: true)
                    } catch is CancellationError {
                        // the task was cancelled by us below, in response to the background task expiring.
                        // we ignore this; no need to do anything.
                    } catch {
                        MHCBackgroundTasks.track(.stop, for: definition.id)
                        task.setTaskCompleted(success: false)
                    }
                }
                task.expirationHandler = {
                    asyncTask.cancel()
                    MHCBackgroundTasks.track(.expiration, for: definition.id)
                    try? self.schedule(definition.id)
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
                Self(date: nil)
            }
            
            fileprivate let date: Date?
            
            static func absolute(_ date: Date) -> Self {
                Self(date: date)
            }
            static func next(_ components: DateComponents) -> Self {
                Self(date: Calendar.current.nextDate(after: .now, matching: components, matchingPolicy: .nextTime))
            }
            static func next(_ rule: Calendar.RecurrenceRule) -> Self {
                Self(date: rule.recurrences(of: .now).first { _ in true })
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
                request.earliestBeginDate = nextTriggerDate.date
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
                request.earliestBeginDate = nextTriggerDate.date
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
                request.earliestBeginDate = nextTriggerDate.date
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
