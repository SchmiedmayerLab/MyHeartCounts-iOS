//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SFSafeSymbols
import SwiftUI


struct DemographicsButton: View {
    let allowDragToDismiss: Bool
    
    @State private var isPresentingSheet = false
    @State private var isComplete = false
    
    var body: some View {
        Button {
            isPresentingSheet = true
        } label: {
            Label("Demographics", systemSymbol: .personTextRectangle)
        }
        .sheet(isPresented: $isPresentingSheet) {
            NavigationStack {
                DemographicsForm(isComplete: $isComplete)
                    .interactiveDismissDisabled(!allowDragToDismiss)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            if #available(iOS 26, *) {
                                Button(role: .confirm) {
                                    isPresentingSheet = false
                                }
                                .disabled(!isComplete)
                            } else {
                                Button("Done") {
                                    isPresentingSheet = false
                                }
                                .bold()
                                .disabled(!isComplete)
                            }
                        }
                    }
            }
        }
    }
}
