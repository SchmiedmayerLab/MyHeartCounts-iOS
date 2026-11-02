//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveOnboarding
import GroveStudyDefinition
import GroveViews
import SFSafeSymbols
import SwiftUI


/// A study variant's Participant Information Sheet, which participants read before the consent form.
///
/// Only study bundles that contain the sheet show it; the Imperial study requires it.
struct ParticipantInformationSheet: View {
    static let fileRef = StudyBundle.FileReference(category: .consent, filename: "ParticipantInformation", fileExtension: "md")
    
    @Environment(ManagedNavigationStack.Path.self)
    private var path
    
    private let document: MarkdownDocument
    private let continueAction: (@MainActor () -> Void)?
    
    var body: some View {
        OnboardingPage(symbol: .textDocument, title: "Participant Information Sheet", description: nil) {
            MarkdownView(document: document)
        } footer: {
            PageActions("Continue") {
                if let continueAction {
                    continueAction()
                } else {
                    path.nextStep()
                }
            }
        }
        .scrollIndicators(.visible)
    }
    
    /// - parameter continueAction: An action which should be performed when the participant continues to the consent.
    ///     Defaults to `nil`, in which case the view advances its `ManagedNavigationStack`.
    init(document: MarkdownDocument, continueAction: (@MainActor () -> Void)? = nil) {
        self.document = document
        self.continueAction = continueAction
    }
}
