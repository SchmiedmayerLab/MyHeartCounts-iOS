//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveStudyDefinition
import GroveViews
import MHCStudyDefinition
import MyHeartCountsShared
import SwiftUI


/// A study variant's privacy notice, which the app shows in place of a privacy policy website.
///
/// Only study bundles that contain the notice show it; the Imperial study requires it.
struct PrivacyNotice: View {
    static let fileRef = StudyBundle.FileReference(category: .consent, filename: "PrivacyNotice", fileExtension: "md")
    
    let document: MarkdownDocument
    
    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownView(document: document)
                    .padding()
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DismissButton()
                }
            }
        }
    }
}


/// A link to the study's privacy policy.
///
/// Opens the privacy notice in the study bundle if it has one, and otherwise the privacy policy on the study's website, if there is one.
struct PrivacyPolicyLink<Label: View>: View {
    @MainActor private static var websiteURL: URL? {
        switch StudyVariant.current {
        case .stanford:
            "https://myheartcounts.stanford.edu/privacy"
        case .imperial:
            nil // Imperial's privacy notice only exists in its study bundle
        }
    }
    
    @Environment(ConsentManager.self)
    private var consentManager: ConsentManager?
    
    @State private var isPresentingPrivacyNotice = false
    
    private let label: Label
    
    var body: some View {
        if let privacyNotice = consentManager?.loadPrivacyNotice() {
            Button {
                isPresentingPrivacyNotice = true
            } label: {
                label
            }
            .sheet(isPresented: $isPresentingPrivacyNotice) {
                PrivacyNotice(document: privacyNotice)
            }
        } else if let url = Self.websiteURL {
            Link2(url) {
                label
            }
        }
    }
    
    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }
    
    init(_ title: LocalizedStringResource) where Label == Text {
        self.init {
            Text(title)
        }
    }
}
