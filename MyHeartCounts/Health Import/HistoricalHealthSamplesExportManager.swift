//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseStorage
import Foundation
import Grove
import GroveAccount
import GroveFoundation
import GroveHealthKit
import GroveHealthKitBulkExport
import GroveStudy
import MyHeartCountsShared
import OSLog
import UIKit


@Observable
@MainActor
final class HistoricalHealthSamplesExportManager: Module, EnvironmentAccessible, Sendable {
    enum CreateBulkExportSessionError: Error {
        case noStudy
        case multipleExportComponents
        case other(any Error)
    }
    
    // swiftlint:disable attributes
    @ObservationIgnored @StandardActor private var standard: MyHeartCountsStandard
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager: StudyManager?
    @ObservationIgnored @Dependency(Account.self) private var account: Account?
    @ObservationIgnored @Dependency(BulkHealthExporter.self) private var bulkExporter
    @ObservationIgnored @Dependency(ManagedFileUpload.self) var managedFileUpload
    // swiftlint:enable attributes
    
    private(set) var session: (any BulkExportSession<HealthKitSamplesFHIRUploader>)?
    @ObservationIgnored private var deferredStartTask: Task<Void, Never>?
    @ObservationIgnored private var isResetting = false
    @ObservationIgnored private var restoresBatteryMonitoring = false
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    func configure() {
        if let account, account.signedIn {
            startAutomaticExportingIfNeeded()
        } else {
            logger.notice("Skipping initial historical upload trigger bc not logged in")
        }
    }

    /// Starts the automatic collection of historical health data,
    /// unless it's already running, or automatic collection is disabled via ``FeatureFlags/disableAutomaticBulkHealthExport``.
    nonisolated func startAutomaticExportingIfNeeded() {
        Task { @MainActor in
            await setupAndStartExportSession()
        }
    }
    
    
    /// Cancels the session, deletes all progress associated with it, and restarts it
    ///
    /// - Note: This is intended primarily for debugging purposes
    func fullyResetSession(restart: Bool = true, clearPendingUploads: Bool = true) async throws {
        isResetting = true
        defer {
            isResetting = false
        }
        stopWaitingForSuitablePower()
        let startTask = startTask
        startTask?.cancel()
        _ = await startTask?.value
        self.startTask = nil
        completionTask?.cancel()
        _ = await completionTask?.value
        completionTask = nil
        if let session {
            await session.pause()
        }
        try await bulkExporter.deleteSessionRestorationInfo(for: .mhcHistoricalDataExport)
        if clearPendingUploads {
            try await managedFileUpload.clearPendingUploads(for: .historicalHealthUpload)
        }
        self.session = nil
        if restart {
            isResetting = false
            await self.setupAndStartExportSession()
        }
    }
    
    
    /// - returns: A Boolean indicating whether the session was successfully set up and started
    @discardableResult
    private func setupAndStartExportSession() async -> Bool {
        guard !isResetting else {
            return false
        }
        if let startTask {
            return await startTask.value
        }
        let startTask = Task { @MainActor [weak self] in
            guard let self else {
                return false
            }
            return await performSetupAndStartExportSession()
        }
        self.startTask = startTask
        let started = await startTask.value
        if self.startTask == startTask {
            self.startTask = nil
        }
        return started
    }

    private func performSetupAndStartExportSession() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard !FeatureFlags.disableAutomaticBulkHealthExport else {
            return false
        }
        guard DeviceBattery.isCharging, !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            logger.notice("Deferring historical upload until the device is charging")
            waitForSuitablePower()
            return false
        }
        stopWaitingForSuitablePower()
        let preferences = LocalPreferencesStore.standard
        let accountDataGeneration = preferences[.accountDataGeneration]
        guard !preferences[.pendingAccountDataCleanupRequired] else {
            logger.notice("Skipping historical upload while cleanup from the previous account is pending")
            return false
        }
        guard let session = try? await getSession() else {
            return false
        }
        guard !Task.isCancelled, isCurrent(accountDataGeneration) else {
            return false
        }
        self.session = session
        guard session.state != .running else {
            return true
        }
        do {
            logger.notice("Will start BulkHealthExport session")
            let batchResults: AsyncStream<HealthKitSamplesFHIRUploader.Output> = try session.start(
                retryFailedBatches: true,
                // Each batch retains samples, FHIR resources, and encoded output in memory.
                concurrencyLevel: .limit(ProcessInfo.isProDevice ? 2 : 1)
            )
            trackCompletion(of: session, batchResults: batchResults, accountDataGeneration: accountDataGeneration)
            return true
        } catch {
            logger.error("Error starting session: \(error)")
            return false
        }
    }


    private func waitForSuitablePower() {
        guard deferredStartTask == nil else {
            return
        }
        let device = UIDevice.current
        restoresBatteryMonitoring = !device.isBatteryMonitoringEnabled
        let powerChanges = powerStateChanges()
        deferredStartTask = Task { @MainActor [weak self] in
            if let self, await startDeferredExportIfPowerIsSuitable() {
                return
            }
            for await _ in powerChanges {
                guard !Task.isCancelled else {
                    return
                }
                if let self, await startDeferredExportIfPowerIsSuitable() {
                    return
                }
            }
        }
        device.isBatteryMonitoringEnabled = true
    }

    private func powerStateChanges() -> AsyncStream<Void> {
        let batteryStateDidChange = UIDevice.batteryStateDidChangeNotification
        let lowPowerModeDidChange = Notification.Name.NSProcessInfoPowerStateDidChange
        return AsyncStream { continuation in
            let observationTask = Task { @concurrent in
                await withDiscardingTaskGroup { group in
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: batteryStateDidChange) {
                            continuation.yield()
                        }
                    }
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: lowPowerModeDidChange) {
                            continuation.yield()
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                observationTask.cancel()
            }
        }
    }

    private func startDeferredExportIfPowerIsSuitable() async -> Bool {
        guard !Task.isCancelled, deferredStartTask != nil else {
            return false
        }
        guard DeviceBattery.isCharging, !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            return false
        }
        deferredStartTask = nil
        restoreBatteryMonitoringIfNeeded()
        await setupAndStartExportSession()
        return true
    }

    private func stopWaitingForSuitablePower() {
        deferredStartTask?.cancel()
        deferredStartTask = nil
        restoreBatteryMonitoringIfNeeded()
    }

    private func restoreBatteryMonitoringIfNeeded() {
        if restoresBatteryMonitoring {
            UIDevice.current.isBatteryMonitoringEnabled = false
            restoresBatteryMonitoring = false
        }
    }
    
    
    private func getSession() async throws(CreateBulkExportSessionError) -> some BulkExportSession<HealthKitSamplesFHIRUploader> {
        guard let study = studyManager?.studyEnrollments.first?.studyBundle?.studyDefinition else {
            throw .noStudy
        }
        let healthCollectionComponents = study.healthDataCollectionComponents.filter {
            $0.historicalDataCollection != .disabled
        }
        guard healthCollectionComponents.count <= 1 else {
            logger.error("Error creating BulkExportSession: multiple data collection components in StudyBundle!")
            throw .multipleExportComponents
        }
        guard let component = healthCollectionComponents.first else {
            throw .noStudy
        }
        switch component.historicalDataCollection {
        case .disabled:
            // unreachable
            throw .noStudy
        case .enabled(let startDate):
            do {
                return try await bulkExporter.session(
                    withId: .mhcHistoricalDataExport,
                    // The bulk exporter does not ask for permission to read the samples, so it's safe to always pass in everything.
                    for: study.allCollectedHealthData(includingOptionalSampleTypes: true),
                    startDate: startDate,
                    using: await HealthKitSamplesFHIRUploader(standard: standard)
                )
            } catch {
                throw .other(error)
            }
        }
    }

    isolated deinit {
        stopWaitingForSuitablePower()
        completionTask?.cancel()
    }
}


// MARK: Completion Tracking

extension HistoricalHealthSamplesExportManager {
    private func trackCompletion(
        of session: any BulkExportSession<HealthKitSamplesFHIRUploader>,
        batchResults: AsyncStream<HealthKitSamplesFHIRUploader.Output>,
        accountDataGeneration: Int
    ) {
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            // the stream ends once the session has reached its final state
            for await _ in batchResults { }
            guard !Task.isCancelled, let self else {
                return
            }
            await recordCompletionIfConcluded(of: session, accountDataGeneration: accountDataGeneration)
        }
    }

    /// Records the conclusion of the historical upload in the account, once every batch was processed without failures
    /// and every resulting file has been uploaded.
    private func recordCompletionIfConcluded(
        of session: any BulkExportSession<HealthKitSamplesFHIRUploader>,
        accountDataGeneration: Int
    ) async {
        guard session.state == .completed, session.failedBatches.isEmpty, let account, account.signedIn else {
            return
        }
        await account.waitForAccountDetailsReady()
        guard isCurrent(accountDataGeneration), account.details?.historicalHealthUploadCompletedDate == nil else {
            return
        }
        do {
            try await managedFileUpload.waitUntilDrained(.historicalHealthUpload)
        } catch {
            return
        }
        guard isCurrent(accountDataGeneration), account.signedIn, account.details?.historicalHealthUploadCompletedDate == nil else {
            return
        }
        var details = AccountDetails()
        details.historicalHealthUploadCompletedDate = .now
        do {
            try await account.accountService.updateAccountDetails(AccountModifications(modifiedDetails: details))
            logger.notice("Recorded conclusion of the historical health upload")
        } catch {
            logger.error("Unable to record conclusion of the historical health upload: \(error)")
        }
    }

    private func isCurrent(_ accountDataGeneration: Int) -> Bool {
        let preferences = LocalPreferencesStore.standard
        return preferences[.accountDataGeneration] == accountDataGeneration && !preferences[.pendingAccountDataCleanupRequired]
    }
}


extension BulkExportSessionIdentifier {
    static let mhcHistoricalDataExport = Self("mhcHistoricalDataExport")
}


extension ManagedFileUpload.Category {
    static let liveHealthUpload = Self(
        id: "HealthKitUpload/live",
        title: "HealthKit Upload (Live)",
        firebasePath: "liveHealthSamples"
    )
    static let historicalHealthUpload = Self(
        id: "HealthKitUpload/historical",
        title: "HealthKit Upload (Historical)",
        firebasePath: "historicalHealthSamples"
    )
    static let healthDeletions = Self(
        id: "HealthKitUpload/deletions",
        title: "HealthKit Deletions",
        firebasePath: "healthDeletions"
    )
}
