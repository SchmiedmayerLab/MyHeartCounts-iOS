//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import AsyncAlgorithms
import Foundation
import OSLog
import Spezi
import SpeziAccount
import SwiftUI


final class EnvironmentTracking: ServiceModule, @unchecked Sendable {
    private enum Entry: Sendable {
        case stream(
            sequence: @Sendable () -> any AsyncSequence<Void, Never>,
            update: @Sendable (EnvironmentTracking) async -> Void
        )
        case custom(
            setup: @Sendable (_ update: @escaping @Sendable () async -> Void) -> Void,
            update: @Sendable (EnvironmentTracking) async -> Void
        )
        
        static func stream(
            _ stream: @autoclosure @escaping @Sendable () -> some AsyncSequence<some Any, Never> & SendableMetatype,
            update: @escaping @Sendable (EnvironmentTracking) async -> Void
        ) -> Self {
            Self.stream(
                sequence: { stream().map { _ in () } as any AsyncSequence<Void, Never> },
                update: update
            )
        }
        
        static func notifications(
            _ name: Notification.Name,
            update: @escaping @Sendable (EnvironmentTracking) async -> Void
        ) -> Self {
            Self.stream(NotificationCenter.default.notifications(named: name), update: update)
        }
    }
    
    // swiftlint:disable attributes
    @Application(\.logger) private var logger
    @Dependency(Lifecycle.self) private var lifecycle
    @Dependency(Account.self) private var account: Account?
    @MainActor private var entries: [Entry] = []
    // swiftlint:enable attributes
    
    func configure() {
        entries = [
            .custom { [weak self] update in
                self?.lifecycle.onChange(of: \.scenePhase, initial: true) { _, _ in
                    Task {
                        await update()
                    }
                }
            } update: { tracking in
                guard tracking.lifecycle.scenePhase == .active else {
                    return
                }
                try? await tracking.updateUserCollectionValues(
                    (\.lastActiveDate, .now)
                )
            },
            .notifications(UIApplication.significantTimeChangeNotification) { tracking in
                try? await tracking.updateUserCollectionValues(
                    (\.timeZone, TimeZone.current.identifier)
                )
            },
            // swiftlint:disable:next legacy_objc_type
            .notifications(NSLocale.currentLocaleDidChangeNotification) { tracking in
                let locale = Locale.current
                try? await tracking.updateUserCollectionValues(
                    (\.language, locale.language.languageCode?.identifier ?? "en"),
                    (\.preferredMeasurementSystem, locale.measurementSystem.identifier)
                )
            }
        ]
    }
    
    func run() async {
        let entries = await entries
        await withDiscardingTaskGroup { taskGroup in
            for entry in entries {
                switch entry {
                case let .stream(sequence, update):
                    taskGroup.addTask {
                        for await _ in sequence() {
                            await update(self)
                        }
                    }
                case let .custom(setup, update):
                    setup { [weak self] in
                        guard let self else {
                            return
                        }
                        await update(self)
                    }
                }
            }
        }
    }
    
    /// Triggers unconditional updates for all tracked fields.
    func triggerAll() async {
        for entry in await entries {
            switch entry {
            case .stream(sequence: _, let update), .custom(setup: _, let update):
                await update(self)
            }
        }
    }
}


extension EnvironmentTracking {
    private func updateUserCollectionValues<each T>(
        _ entry: repeat (WritableKeyPath<AccountDetails, (each T)?>, (each T)?)
    ) async throws {
        guard let account else {
            return
        }
        let current = await account.details
        var updated = AccountDetails()
        var removed = AccountDetails()
        for (keyPath, newValue) in repeat each entry {
            if let newValue {
                updated[keyPath: keyPath] = newValue
            } else {
                removed[keyPath: keyPath] = current?[keyPath: keyPath]
            }
        }
        try await account.accountService.updateAccountDetails(.init(modifiedDetails: updated, removedAccountDetails: removed))
    }
}
