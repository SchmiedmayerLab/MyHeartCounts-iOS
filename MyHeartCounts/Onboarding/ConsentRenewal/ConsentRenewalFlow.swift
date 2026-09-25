//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import GroveAccount
import GroveConsent
import GroveOnboarding
import GroveViews
import SFSafeSymbols
import SwiftUI


struct ConsentRenewalFlow: View {
    @Environment(\.dismiss)
    private var dismiss
    
    let document: ConsentDocument
    
    var body: some View {
        ManagedNavigationStack {
            ConsentRenewalExplainer()
            Consent(document: document) {
                dismiss()
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("MHC:ConsentRenewalFlow")
    }
}


private struct ConsentRenewalExplainer: View {
    // swiftlint:disable attributes
    @Environment(ManagedNavigationStack.Path.self) private var path
    @Environment(Account.self) private var account: Account?
    // swiftlint:enable attributes
    
    var body: some View {
        OnboardingPage(
            symbol: .signature,
            title: "Consent Renewal",
            description: nil
        ) {
            let lastSignDate = account?.details?.lastSignedConsentDate
            Text("""
                Our Study Consent document has been updated since you last signed it\(lastSignDate.map { " on \($0.formatted(.dateTime))" } ?? "").

                Please review the new Consent document and sign it again.
                """)
            Spacer()
        } footer: {
            OnboardingActionsView("Continue") {
                path.nextStep()
            }
        }
    }
}
