//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import FirebaseFunctions
import SFSafeSymbols
import SpeziAccount
import SpeziOnboarding
import SpeziViews
import SwiftUI


struct AccountOnboarding: View {
    @Environment(ManagedNavigationStack.Path.self)
    private var path
    
    @Environment(MyHeartCountsStandard.self)
    private var standard
    
    var body: some View {
        VStack {
            AccountSetup { details in
                Task {
                    // Placing the nextStep() call inside this task will ensure that the sheet dismiss animation is
                    // played till the end before we navigate to the next step.
                    advance(details)
                }
            } header: {
                AccountSetupHeader()
            } continue: {
                // action if the user already is logged in
                OnboardingActionsView("Next") {
                    await advance(standard.account?.details ?? AccountDetails())
                }
            }
            // NOTE: ideally we'd have this be semantically part of the AccountSetup (pushed all the way to the bottom),
            // but since that is a ScrollView er have no easy way to achieve this, so we put it here instead, for the time being.
            Spacer()
            Link2("Privacy Policy", MyHeartCounts.website(.privacyPolicy))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(Text(verbatim: ""))
        .toolbar(.visible)
    }
    
    private func advance(_ details: AccountDetails) {
        if details.hasWithdrawnFromStudy == true {
            path.append {
                ReactivatePreviouslyWithdrawnAccount()
                    .injectingSpezi()
                    .navigationBarBackButtonHidden()
            }
        } else {
            path.nextStep()
        }
    }
}


private struct ReactivatePreviouslyWithdrawnAccount: View {
    @Environment(ManagedNavigationStack.Path.self)
    private var path
    
    @Environment(Account.self)
    private var account
    
    var body: some View {
        OnboardingPage(
            symbol: .personCropCircle,
            title: "REACTIVATE_WITHDRAWN_ACCOUNT_TITLE",
            description: "REACTIVATE_WITHDRAWN_ACCOUNT_MESSAGE"
        ) {
            EmptyView()
        } footer: {
            OnboardingActionsView(
                primaryTitle: "Reactivate Account",
                primaryAction: {
                    _ = try await Functions.functions()
                        .httpsCallable("markAccountForStudyReenrollment")
                        .call([:])
                    path.nextStep()
                },
                secondaryTitle: "Don't reactivate",
                secondaryAction: {
                    try await account.accountService.logout()
                    // go back to Login step
                    path.removeLast()
                }
            )
        }
    }
}
