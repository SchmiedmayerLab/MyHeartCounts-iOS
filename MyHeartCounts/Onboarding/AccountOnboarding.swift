//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import FirebaseFunctions
import GroveAccount
import class GroveConsent.ConsentDocument
import GroveOnboarding
import GroveViews
import SFSafeSymbols
import SwiftUI


struct AccountOnboarding: View {
    // swiftlint:disable attributes
    @Environment(ManagedNavigationStack.Path.self) private var path
    @Environment(MyHeartCountsStandard.self) private var standard
    @Environment(ConsentManager.self) private var consentManager
    // swiftlint:enable attributes
    
    @State private var consentDoc: ConsentDocument?
    
    var body: some View {
        VStack {
            AccountSetup { details in
                Task {
                    await Task.yield()
                    // Placing the nextStep() call inside this task will ensure that the sheet dismiss animation is
                    // played till the end before we navigate to the next step.
                    try? await advance(details)
                }
            } header: {
                AccountSetupHeader()
            } continue: {
                // action if the user already is logged in
                OnboardingActionsView("Next") {
                    try await advance(standard.account?.details ?? AccountDetails())
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
    
    private func advance(_ details: AccountDetails) async throws {
        let consentDoc = try await consentDocumentToSign()
        if details.hasWithdrawnFromStudy == true {
            path.append {
                ReactivatePreviouslyWithdrawnAccount {
                    advance(consentDocToSign: consentDoc)
                }
                .injectingGrove()
                .navigationBarBackButtonHidden()
            }
        } else {
            advance(consentDocToSign: consentDoc)
        }
    }
    
    private func advance(consentDocToSign: ConsentDocument?) {
        if let consentDocToSign {
            self.consentDoc = consentDocToSign
            path.append {
                ConsentDisclaimers(consentDoc: consentDocToSign)
                    // we hide the back button here, to prevent the user from returning to the "re-activate account" page
                    // (in case that's presented), since that yes/no decision should only be made once.
                    .navigationBarBackButtonHidden()
            }
        } else {
            // the user does not need to go through the whole flow,
            // so we go to the next regularly scheduled step
            path.nextStep()
        }
    }
    
    
    private func consentDocumentToSign() async throws -> ConsentDocument? {
        let doc = try await consentManager.loadConsentDoc()
        switch try consentManager.shouldSign(doc.metadata) {
        case .no:
            // the user does not need to go through the whole flow,
            // so we go to the next regularly scheduled step
            return nil
        case .yes:
            // the user needs to go through the whole consent flow
            return doc
        }
    }
}


private struct ReactivatePreviouslyWithdrawnAccount: View {
    @Environment(ManagedNavigationStack.Path.self)
    private var path
    
    @Environment(Account.self)
    private var account
    
    let onReactivation: () -> Void
    
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
                    onReactivation()
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
