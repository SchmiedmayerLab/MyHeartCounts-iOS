//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseStorage
import Foundation
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziAccount
import SpeziHealthKit
import SpeziHealthKitBulkExport
import SpeziStudy


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
        Task {
            await setupAndStartExportSession()
        }
    }
    
    
    /// Cancels the session, deletes all progress associated with it, and restarts it
    ///
    /// - Note: This is intended primarily for debugging purposes
    func fullyResetSession(restart: Bool = true) async throws {
        try await bulkExporter.deleteSessionRestorationInfo(for: .mhcHistoricalDataExport)
        try? managedFileUpload.clearPendingUploads(for: .historicalHealthUpload)
        self.session = nil
        if restart {
            await self.setupAndStartExportSession()
        }
    }
    
    
    /// - returns: A Boolean indicating whether the session was successfully set up and started
    @discardableResult
    private func setupAndStartExportSession() async -> Bool {
        guard !FeatureFlags.disableAutomaticBulkHealthExport else {
            return false
        }
        guard let session = try? await getSession() else {
            return false
        }
        self.session = session
        do {
            logger.notice("Will start BulkHealthExport session")
            let results = try session.start(
                retryFailedBatches: true,
                concurrencyLevel: .limit(ProcessInfo.isProDevice ? 4 : 2)
            )
            managedFileUpload.scheduleForUpload(results.compactMap { $0 }, category: .historicalHealthUpload)
            return true
        } catch {
            logger.error("Error starting session: \(error)")
            return false
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
                    using: HealthKitSamplesFHIRUploader(standard: standard)
                )
            } catch {
                throw .other(error)
            }
        }
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
