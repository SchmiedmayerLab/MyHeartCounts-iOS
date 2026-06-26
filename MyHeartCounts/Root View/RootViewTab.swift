//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import SFSafeSymbols
import SpeziAccount
import SwiftUI


/// A `View` that constitutes one of the tabs in the MHC app's root-level `TabView`.
protocol RootViewTab: View {
    nonisolated static var tabId: String { get }
    static var tabTitle: LocalizedStringResource { get }
    static var tabSymbol: SFSymbol { get }
    
    init()
}


extension RootViewTab {
    nonisolated static var tabId: String {
        String(describing: Self.self)
    }
}


extension RootViewTab {
    /// A `ToolbarItem` consisting of a Button which will present the account management sheet.
    ///
    /// ``RootViewTab``s should include this in their respective toolbars.
    var accountToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            AccountToolbarButton()
        }
    }
}


private struct AccountToolbarButton: View {
    @Environment(Account.self)
    private var account: Account?
    
    @State private var isPresentingAccount = false
    
    var body: some View {
        if account != nil {
            // NOTE: ideally, we'd simply have the following here:
            // ```
            // Button("Your Account", systemImage: "person.crop.circle") {
            //     isPresentingAccount = true
            // }
            // ```
            // but: this does not work on iOS 26.4+, since for some reason presenting a sheet from a Button with a systemImage within a toolbar item
            // causes the sheet to reset to its initial value when the app is closed and reopened. (FB22483867)
            // so we work around this by giving the button a custom image (which seems to work, since it's not a Label) abd then adding an accessibilityLabel to the whole thing.
            // this means that the button is only usable for image-only contexts, but since it's only used for ToolbarItems, we'll be fine here.
            Button {
                isPresentingAccount = true
            } label: {
                Image(systemSymbol: .personCropCircle)
            }
            .accessibilityIdentifier("MHC:YourAccount")
            .accessibilityLabel("Your Account")
            .sheet(isPresented: $isPresentingAccount) {
                AccountSheet()
            }
        }
    }
}
