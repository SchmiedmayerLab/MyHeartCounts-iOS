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
/// The study's privacy notice, if it has one, follows the sheet.
struct ParticipantInformationSheet: View {
    static let fileRef = StudyBundle.FileReference(category: .consent, filename: "ParticipantInformation", fileExtension: "md")
    
    @Environment(ManagedNavigationStack.Path.self)
    private var path
    
    private let document: MarkdownDocument
    private let privacyNotice: MarkdownDocument?
    private let continueAction: (@MainActor () -> Void)?
    
    var body: some View {
        OnboardingPage(symbol: .textDocument, title: "Participant Information Sheet", description: nil) {
            MarkdownView(document: document)
            if let privacyNotice {
                MarkdownView(document: privacyNotice)
            }
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
    
    /// - parameter privacyNotice: The study's privacy notice, which the view shows after the sheet.
    /// - parameter continueAction: An action which should be performed when the participant continues to the consent.
    ///     Defaults to `nil`, in which case the view advances its `ManagedNavigationStack`.
    init(document: MarkdownDocument, privacyNotice: MarkdownDocument?, continueAction: (@MainActor () -> Void)? = nil) {
        self.document = document
        self.privacyNotice = privacyNotice
        self.continueAction = continueAction
    }
}
