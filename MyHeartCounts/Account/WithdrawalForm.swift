//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveConsent
import GroveStudy
import GroveStudyDefinition
import GroveViews
import SwiftUI


/// A form in which participants sign their withdrawal from the study; the signed form is uploaded next to their consent forms.
///
/// Only study bundles that contain the form require it; the Imperial study does.
struct WithdrawalForm: View {
    static let fileRef = StudyBundle.FileReference(category: .consent, filename: "Withdrawal", fileExtension: "md")
    
    // swiftlint:disable attributes
    @Environment(\.dismiss) private var dismiss
    @Environment(MyHeartCountsStandard.self) private var standard
    @Environment(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    private let document: ConsentDocument
    private let onSigned: @MainActor () -> Void
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        NavigationStack {
            ScrollView {
                ConsentDocumentView(consentDocument: document, consentSignatureDate: .now) {
                    AsyncButton(role: .destructive, state: $viewState) {
                        let result = try document.export(using: .init(paperSize: studyManager.preferredLocale.preferredPaperSize))
                        try await standard.uploadConsentDocument(result)
                        onSigned()
                        dismiss()
                    } label: {
                        Text("Withdraw from Study")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(document.completionState != .complete)
                }
                .padding()
            }
            .scrollDisabled(document.isSigning)
            .navigationTitle("Withdraw from Study")
            .navigationBarTitleDisplayMode(.inline)
            .viewStateAlert(state: $viewState)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(viewState != .idle)
                }
            }
        }
        .interactiveDismissDisabled(viewState != .idle)
    }
    
    /// - parameter onSigned: Called once the participant has signed the form and it has been uploaded.
    init(document: ConsentDocument, onSigned: @escaping @MainActor () -> Void) {
        self.document = document
        self.onSigned = onSigned
    }
}
