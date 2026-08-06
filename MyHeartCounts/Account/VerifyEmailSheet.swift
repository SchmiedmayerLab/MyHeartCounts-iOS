//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseAuth
import Foundation
import MyHeartCountsShared
import SFSafeSymbols
import SpeziAccount
import SpeziFirebaseAccount
import SpeziFoundation
import SpeziViews
import SwiftUI


struct VerifyEmailSheet: View {
    // swiftlint:disable attributes
    @Environment(\.dismiss) private var dismiss
    @Environment(Account.self) private var account
    @Environment(FirebaseAccountService.self) private var accountService
    // swiftlint:enable attributes
    
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        NavigationStack { // swiftlint:disable:this closure_body_length
            OnboardingPage(
                symbol: .personBadgeShieldCheckmark,
                title: "Verify Email",
                description: "EMAIL_VERIFICATION_SHEET_EXPLAINER"
            ) {
                if let details = account.details {
                    VStack(alignment: .leading, spacing: 17) {
                        primaryContent(isVerified: details.isVerified, email: details.userId)
                    }
                } else {
                    Text("EMAIL_VERIFICATION_SHEET_NO_ACCOUNT")
                }
            }
            .viewStateAlert(state: $viewState)
            .toolbar {
                let isVerified = account.details?.isVerified ?? false
                ToolbarItem(placement: isVerified ? .confirmationAction : .cancellationAction) {
                    if #available(iOS 26, *) {
                        Button(role: isVerified ? .confirm : .cancel) {
                            dismiss()
                        }
                    } else {
                        Button(isVerified ? "Done" : "Close") {
                            dismiss()
                        }
                        .bold(isVerified)
                    }
                }
            }
            .interactiveDismissDisabled(viewState != .idle)
            .task {
                // Firebase does not notify us when verification finishes, so poll while this sheet is open.
                while !Task.isCancelled, account.details?.isVerified != true {
                    do {
                        try await accountService.refresh()
                    } catch {
                        logger.error("Error refreshing user: \(error)")
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
    
    
    @ViewBuilder
    private func primaryContent(isVerified: Bool, email: String) -> some View {
        HStack {
            Image(systemSymbol: isVerified ? .checkmarkShield : .exclamationmarkShield)
                .foregroundStyle(isVerified ? .green : .orange)
                .accessibilityHidden(true)
            Text(isVerified ? "EMAIL_VERIFICATION_SHEET_STATUS_IS_VERIFIED" : "EMAIL_VERIFICATION_SHEET_STATUS_IS_NOT_VERIFIED")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.all, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        if !isVerified {
            verificationFlow(email: email)
                .padding(.top, 20)
        }
    }
    
    @ViewBuilder
    private func verificationFlow(email: String) -> some View {
        VStack(spacing: 17) {
            Text("How to verify")
                .font(.headline)
            makeRow(
                stepTitle: "1. Request a verification link",
                stepExplainer: "We'll email a link to \(email)",
                buttonTitle: "Get Link"
            ) {
                guard let user = Auth.auth().currentUser else {
                    return
                }
                try await user.sendEmailVerification()
            }
            makeRow(
                stepTitle: "2. Open the link in the email",
                stepExplainer: "Tap the link in the email to complete the verification, then return here.",
                buttonTitle: "Open Mail"
            ) {
                await UIApplication.shared.open("message://")
            }
        }
    }
    
    
    private func makeRow(
        stepTitle: LocalizedStringResource,
        stepExplainer: LocalizedStringResource,
        buttonTitle: LocalizedStringResource,
        buttonAction: @escaping () async throws -> Void
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(stepTitle)
                Spacer()
                AsyncButton(state: $viewState) {
                    try await buttonAction()
                } label: {
                    Text(buttonTitle)
                }
            }
            Text(stepExplainer)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
