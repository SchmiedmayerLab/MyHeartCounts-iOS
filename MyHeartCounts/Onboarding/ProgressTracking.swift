//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import GroveAccount
import SwiftUI


struct OnboardingStep: RawRepresentableAccountKey {
    let rawValue: String
    
    init(rawValue: String) {
        self.rawValue = rawValue
    }
}


private struct OnboardingStepModifier: ViewModifier {
    // swiftlint:disable attributes
    @Environment(\.isInOnboardingFlow) private var isInOnboarding
    @Environment(Account.self) private var account: Account?
    // swiftlint:enable attributes
    
    let step: OnboardingStep
    
    func body(content: Content) -> some View {
        content.task {
            guard isInOnboarding, let account else {
                return
            }
            do {
                var details = AccountDetails()
                details.mostRecentOnboardingStep = step
                let modifications = try AccountModifications(modifiedDetails: details)
                try await account.accountService.updateAccountDetails(modifications)
            } catch {
                print("Error updating most recent onboarding step: \(error)")
            }
        }
    }
}


extension EnvironmentValues {
    @Entry var isInOnboardingFlow: Bool = false
}


extension View {
    func onboardingStep(_ step: OnboardingStep) -> some View {
        self.modifier(OnboardingStepModifier(step: step))
    }
}
