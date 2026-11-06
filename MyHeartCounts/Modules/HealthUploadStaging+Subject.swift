//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFoundation
import GroveHealthKitFHIR


extension HealthUploadStaging {
    /// The exporter of one staged batch and the subject its rows are stored under, fenced to `accountDataGeneration`: the
    /// app's one HealthKit exporter, and the subject it was built for.
    func stagingExporter(accountDataGeneration: Int) async throws -> HealthKitExporterHolder.Current {
        #if DEBUG
        if let testing {
            return HealthKitExporterHolder.Current(
                exporter: try await testing.healthKitExporter(subject: testing.subject),
                subject: testing.subject
            )
        }
        #endif
        return try healthKitExporterHolder.current(forBatchOf: accountDataGeneration)
    }

    /// The exporter of one staged batch, fenced to `accountDataGeneration`.
    func healthKitExporter(accountDataGeneration: Int) async throws -> HealthKitFHIRExporter {
        try await stagingExporter(accountDataGeneration: accountDataGeneration).exporter
    }

    /// The subject a deletion reported under `accountDataGeneration` is stored under: the one the samples staged under
    /// that generation are stored under.
    ///
    /// Throws as ``stagingExporter(accountDataGeneration:)`` does, so a delivery without a subject keeps its anchor.
    func stagingSubject(accountDataGeneration: Int) throws -> FHIRExchangeSubject {
        #if DEBUG
        if let testing {
            return testing.subject
        }
        #endif
        return try healthKitExporterHolder.current(forBatchOf: accountDataGeneration).subject
    }

    /// The exporter that retracts under `subject`: in production the holder's, which must have been built for `subject`.
    ///
    /// - throws: ``FHIRExchangeDestinationError/accountChanged`` when it was not: the account changed mid-drain, which
    ///     leaves the chunk for the next drain.
    func retractionExporter(subject: FHIRExchangeSubject, accountDataGeneration: Int) async throws -> HealthKitFHIRExporter {
        #if DEBUG
        if let testing {
            return try await testing.healthKitExporter(subject: subject)
        }
        #endif
        let current = try healthKitExporterHolder.current(forBatchOf: accountDataGeneration)
        guard subject.isNamed(by: current.subject.identity) else {
            throw FHIRExchangeDestinationError.accountChanged
        }
        return current.exporter
    }
}


#if DEBUG
extension HealthUploadStaging {
    /// What a test stages against instead of the signed-in account and the app's exchange state.
    struct TestingOverrides {
        /// The subject staged samples are attributed to, which every insert stores; a test that changes it between inserts
        /// stages rows of two subjects in one database. The drains take their subject as a parameter and never read it.
        var subject: FHIRExchangeSubject
        /// An isolated identity store, so staging in a test never touches the host's encrypted exchange state.
        var stateStore: FHIRExchangeStateStore
        /// The app facts new records state, so a test can change them between deliveries; `nil` uses the app's.
        var facts: ConversionFacts?

        /// An exporter of `subject` from ``stateStore``, under ``facts``.
        func healthKitExporter(subject: FHIRExchangeSubject) async throws -> HealthKitFHIRExporter {
            if let facts {
                return try stateStore.healthKitExporter(subject: subject, facts: facts)
            }
            return try await stateStore.healthKitExporter(subject: subject)
        }
    }

    /// Stages against a fixed subject and an isolated identity store, standing in for the signed-in account a test has no
    /// way to supply. Compiled out of release builds, so a shipping app always attributes to the account and converts
    /// through the app's exporter.
    nonisolated static func forTesting(
        persistence: Persistence,
        autoElideUploadsWhenInsertingDeletions: Bool = true,
        subject: FHIRExchangeSubject
    ) -> HealthUploadStaging {
        let staging = Self(
            persistence: persistence,
            autoElideUploadsWhenInsertingDeletions: autoElideUploadsWhenInsertingDeletions
        )
        staging.testing = TestingOverrides(
            subject: subject,
            // Fenced to the live preferences, as staging itself is.
            stateStore: FHIRExchangeStateStore(accountDataGeneration: LocalPreferencesStore.standard[.accountDataGeneration])
        )
        return staging
    }
}
#endif
