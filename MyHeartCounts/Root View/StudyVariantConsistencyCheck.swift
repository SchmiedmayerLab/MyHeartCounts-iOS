//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveAccount
import GroveFoundation
import GroveViews
import MHCStudyDefinition
import SFSafeSymbols
import SwiftUI


private struct StudyVariantMismatchError: View {
    @Environment(Account.self)
    private var account: Account?

    let forcedVariant: StudyVariant?
    let enrolledVariant: StudyVariant?
    let accountVariant: StudyVariant?

    @State private var isConfirmingLogout = false
    @State private var viewState: ViewState = .idle

    var body: some View {
        ContentUnavailableView {
            Label("Study Variant Mismatch" as String, systemSymbol: .exclamationmarkOctagon)
        } description: {
            Text(verbatim: "This build, this device's enrollment, and this account belong to different studies.")
            Text(verbatim: """
                Build: \(forcedVariant?.rawValue ?? "n/a")
                Enrollment: \(enrolledVariant?.rawValue ?? "n/a")
                Account: \(accountVariant?.rawValue ?? "n/a")
                """)
                .font(.footnote)
        } actions: {
            if account?.signedIn == true {
                // the error replaces the account sheet, so this is the only way out of here that doesn't involve deleting the app.
                Button("Log Out" as String, role: .destructive) {
                    isConfirmingLogout = true
                }
            }
        }
        .alert("Log Out?" as String, isPresented: $isConfirmingLogout) {
            Button("Cancel" as String, role: .cancel) {}
            AsyncButton("Log Out" as String, role: .destructive, state: $viewState) {
                try await account?.accountService.logout()
            }
        } message: {
            Text(verbatim: "This removes the enrollment from this device, along with any data that hasn't been uploaded yet.")
        }
        .viewStateAlert(state: $viewState)
    }
}


private struct StudyVariantConsistencyCheck: ViewModifier {
    @Environment(Account.self)
    private var account: Account?

    @LocalPreference(.enrolledStudyVariant)
    private var enrolledVariant

    func body(content: Content) -> some View {
        let forcedVariant = FeatureFlags.forcedStudyVariant
        let accountVariant = account?.details?.studyVariant
        let variants = Set([forcedVariant, enrolledVariant, accountVariant].compactMap(\.self))
        if variants.count > 1 && FeatureFlags.isDevelopmentOrTestFlightBuild {
            StudyVariantMismatchError(forcedVariant: forcedVariant, enrolledVariant: enrolledVariant, accountVariant: accountVariant)
        } else {
            // IDEA App Store builds carry on as normal; we might want to report a mismatch to the backend here.
            content
        }
    }
}


extension View {
    /// Replaces the view with an error screen in Debug and TestFlight builds, if the build, the local enrollment, and the account disagree on the study variant.
    func checkingStudyVariantConsistency() -> some View {
        modifier(StudyVariantConsistencyCheck())
    }
}
