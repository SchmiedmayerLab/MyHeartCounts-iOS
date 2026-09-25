//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

@_spi(TestingSupport)
import GroveAccount
import SwiftUI


struct AccountSetupHeader: View {
    @Environment(Account.self)
    private var account
    @Environment(\.accountSetupState)
    private var setupState
    
    
    var body: some View {
        VStack {
            Text("Your Account")
                .font(.largeTitle)
                .bold()
                .padding(.bottom)
                .padding(.top, 30)
            if account.signedIn, case .presentingExistingAccount = setupState {
                Text("ACCOUNT_SIGNED_IN_DESCRIPTION")
            } else {
                Text("ACCOUNT_SETUP_DESCRIPTION")
                    .padding(.bottom, 17)
                Text("ACCOUNT_SETUP_DESCRIPTION_SUBTITLE")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
    }
}
