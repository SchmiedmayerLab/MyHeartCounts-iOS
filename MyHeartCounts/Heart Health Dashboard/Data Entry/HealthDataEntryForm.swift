//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveHealthKit
import GroveViews
import HealthKit
import SFSafeSymbols
import SwiftUI


/// What a ``HealthDataEntryForm`` saves.
enum HealthDataEntry {
    /// Samples of HealthKit types.
    case healthKit([HKSample])
    /// A sample of one of MHC's custom types.
    case custom(QuantitySample)

    /// Where the form saves an entry.
    enum Destination {
        /// Saved into the Health app, from where MHC's HealthKit data collection picks the samples up and uploads them.
        case healthApp([HKSample])
        /// Straight into MHC's upload queue, as the participant doesn't want the samples in the Health app, or MHC may not
        /// save them there (see ``UnsavedHealthKitSample``).
        case healthKitSamplesUpload([HKSample])
        /// Uploaded directly; samples of MHC's custom types only exist in MHC's backend.
        case customSampleUpload(QuantitySample)
    }

    /// Where the form saves the entry: into the Health app only if the participant wants it there (`savingToHealthApp`)
    /// and MHC may save the entry's HealthKit types there (`access`).
    func destination(given access: HealthWriteAccess, savingToHealthApp: Bool) -> Destination {
        switch self {
        case .healthKit(let samples):
            if savingToHealthApp && access == .allowed {
                .healthApp(samples)
            } else {
                .healthKitSamplesUpload(samples)
            }
        case .custom(let sample):
            .customSampleUpload(sample)
        }
    }
}


/// Whether MHC may save samples of a ``HealthDataEntryForm``'s HealthKit types into the Health app.
enum HealthWriteAccess: Equatable {
    case allowed
    /// MHC hasn't asked for access to (some of) the types yet.
    case notAskedYet
    /// The participant didn't allow access to (some of) the types.
    case denied

    /// The access that the write authorization statuses of all of a form's types amount to: a form without HealthKit types
    /// saves nothing into the Health app, so it needs no access.
    init(_ statuses: some Sequence<HKAuthorizationStatus>) {
        let statuses = Set(statuses)
        self = if statuses.contains(.sharingDenied) {
            .denied
        } else if statuses.contains(.notDetermined) {
            .notAskedYet
        } else {
            .allowed
        }
    }
}


/// The shared form of MHC's manual health data entry sheets.
///
/// The form provides the sheet's Cancel and Save buttons, and the saving itself:
/// - Samples of HealthKit types get saved into the Health app, from where MHC's HealthKit data collection picks them up and
///   uploads them, unless the participant turns off "Save to the Health App", which the form offers for them.
/// - If MHC hasn't asked for access to the types yet, saving asks first. If MHC may not save some of the types into the Health
///   app, the toggle is off, and says so.
/// - Samples that aren't saved into the Health app go straight into MHC's upload queue instead. They then reach the study, but
///   don't appear in the Health app or on the dashboard (whose statistics are computed from HealthKit).
/// - Samples of MHC's custom types only exist in MHC's backend, and get uploaded directly.
struct HealthDataEntryForm<Content: View>: View {
    @Environment(HealthKit.self)
    private var healthKit
    @Environment(MyHeartCountsStandard.self)
    private var standard
    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.scenePhase)
    private var scenePhase

    @State private var viewState: ViewState = .idle
    @State private var healthWriteAccess: HealthWriteAccess = .allowed
    /// Whether the participant wants the entry in the Health app, as well.
    @State private var savesToHealthApp = true

    private let title: LocalizedStringKey
    private let healthKitTypes: [HKSampleType]
    private let canSave: Bool
    private let isSaveAllowedToFail: Bool
    private let makeEntry: @MainActor () -> HealthDataEntry?
    private let didSave: @MainActor (HealthDataEntry) -> Void
    private let content: Content

    var body: some View {
        Form {
            content
            if !healthKitTypes.isEmpty {
                healthAppSection
            }
        }
        .navigationTitle(title)
        .viewStateAlert(state: $viewState)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DismissButton()
            }
            ToolbarItem(placement: .confirmationAction) {
                AsyncButton(state: $viewState) {
                    try await save()
                    dismiss()
                } label: {
                    Label("Save", systemSymbol: .checkmark)
                }
                .disabled(!canSave)
                .buttonStyleGlassProminent()
            }
        }
        .onAppear(perform: updateHealthWriteAccess)
        .onChange(of: scenePhase) {
            // the participant might have changed the access in the Settings app
            updateHealthWriteAccess()
        }
    }

    private var healthAppSection: some View {
        Section {
            // without access, the toggle is off and can't be turned on; the footer says why
            Toggle("Save to the Health App", isOn: healthWriteAccess == .denied ? .constant(false) : $savesToHealthApp)
                .disabled(healthWriteAccess == .denied)
                .accessibilityIdentifier("HealthDataEntry:SaveToHealthApp")
        } footer: {
            if healthWriteAccess == .denied {
                Text("HEALTH_DATA_ENTRY_DENIED_NOTICE")
            } else {
                Text("HEALTH_DATA_ENTRY_SAVE_TO_HEALTH_APP_FOOTER")
            }
        }
    }

    /// - parameter title: The sheet's navigation title.
    /// - parameter healthKitTypes: The HealthKit types of the samples the form saves; empty if it saves a custom sample.
    /// - parameter canSave: Whether the entered values are complete and valid.
    /// - parameter isSaveAllowedToFail: Whether a failure to save gets ignored (e.g., because ``didSave`` processes the values itself).
    /// - parameter makeEntry: Creates what the form saves, from the entered values.
    /// - parameter didSave: Called after the form saved the entry.
    init(
        _ title: LocalizedStringKey,
        healthKitTypes: [HKSampleType],
        canSave: Bool,
        isSaveAllowedToFail: Bool = false,
        makeEntry: @escaping @MainActor () -> HealthDataEntry?,
        didSave: @escaping @MainActor (HealthDataEntry) -> Void = { _ in },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.healthKitTypes = healthKitTypes
        self.canSave = canSave
        self.isSaveAllowedToFail = isSaveAllowedToFail
        self.makeEntry = makeEntry
        self.didSave = didSave
        self.content = content()
    }

    private func updateHealthWriteAccess() {
        healthWriteAccess = HealthWriteAccess(healthKitTypes.map { healthKit.healthStore.authorizationStatus(for: $0) })
    }

    private func save() async throws {
        guard canSave, let entry = makeEntry() else {
            return
        }
        updateHealthWriteAccess()
        if case .healthKit = entry, savesToHealthApp, healthWriteAccess == .notAskedYet {
            // if asking fails, the access stays undetermined, and the entry goes straight into the upload queue
            try? await healthKit.askForAuthorization(for: .init(readAndWrite: healthKitTypes))
            updateHealthWriteAccess()
        }
        do {
            switch entry.destination(given: healthWriteAccess, savingToHealthApp: savesToHealthApp) {
            case .healthApp(let samples):
                try await healthKit.save(samples)
            case .healthKitSamplesUpload(let samples):
                // The samples would otherwise reach the upload queue through MHC's HealthKit data collection; their records
                // state MHC as their source, as they would have had MHC saved them.
                try await standard.uploadHealthObservations(samples.map(UnsavedHealthKitSample.init))
            case .customSampleUpload(let sample):
                try await standard.uploadHealthObservation(sample)
            }
        } catch {
            guard isSaveAllowedToFail else {
                throw error
            }
        }
        didSave(entry)
    }
}
