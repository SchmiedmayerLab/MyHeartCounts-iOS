//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveAccount
import GroveViews
import SFSafeSymbols
import SwiftUI


struct UpdateComorbiditiesButton: View {
    @Environment(Account.self)
    private var account
    
    @State private var showSheet = false
    @State private var demographicsData = DemographicsData()
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack {
                Text("UPDATE_COMORBIDITIES_BUTTON_TITLE")
                    .foregroundStyle(.textLabel)
                Spacer()
                DisclosureIndicator()
            }
        }
        .disabled(account.details == nil)
        .sheet(isPresented: $showSheet) {
            @Bindable var data = demographicsData
            NavigationStack {
                ComorbiditiesPicker(selection: $data[\.comorbidities].withDefault(Comorbidities()))
                    .navigationBarTitleDisplayMode(.inline)
                    .interactiveDismissDisabled()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            closeSheetButton
                        }
                    }
            }
            .onAppear {
                demographicsData.populateIfEmpty(from: account)
            }
        }
    }
    
    @ViewBuilder private var closeSheetButton: some View {
        if #available(iOS 26, *) {
            AsyncButton(role: .confirm, state: $viewState) {
                try await closeSheet()
            } label: {
                Label("Done", systemSymbol: .checkmark)
            }
        } else {
            AsyncButton("Done", state: $viewState) {
                try await closeSheet()
            }
        }
    }
    
    private func closeSheet() async throws {
        showSheet = false
        try await demographicsData.flush()
    }
}
