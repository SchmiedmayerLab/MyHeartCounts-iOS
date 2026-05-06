//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import SafariServices
import SwiftUI


enum Link2Style {
    /// Opens the link in the iOS Safari app.
    case iosSafari
    /// Opens the link using an in-app `SFSafariViewController` sheet.
    case inAppSafari
}


/// Alternative to `SwiftUI.Link`, with support for opening the URL in-app using `SFSafariViewController`.
struct Link2<Label: View>: View {
    // swiftlint:disable attributes
    @Environment(\.link2Style) private var style
    @Environment(\.openURL) private var openUrl
    // swiftlint:enable attributes
    private let url: URL
    private let label: Label
    
    @State private var showSheet = false
    
    var body: some View {
        Button {
            openLink()
        } label: {
            label
        }
        .sheet(isPresented: $showSheet) {
            switch style {
            case .iosSafari:
                EmptyView() // unreachable
            case .inAppSafari:
                SFSafariView(url: url)
            }
        }
    }
    
    init(_ url: URL, @ViewBuilder label: () -> Label) {
        self.url = url
        self.label = label()
    }
    
    init(_ title: LocalizedStringResource, _ url: URL) where Label == Text {
        self.init(url) {
            Text(title)
        }
    }
    
    private func openLink() {
        switch style {
        case .inAppSafari:
            showSheet = true
        case .iosSafari:
            openUrl(url)
        }
    }
}


extension EnvironmentValues {
    @Entry var link2Style: Link2Style = .inAppSafari
}


extension View {
    func link2Style(_ style: Link2Style) -> some View {
        self.environment(\.link2Style, style)
    }
}


private struct SFSafariView: UIViewControllerRepresentable {
    private let url: URL
    private let dismissButtonStyle: SFSafariViewController.DismissButtonStyle
    
    init(
        url: URL,
        dismissButtonStyle: SFSafariViewController.DismissButtonStyle = .close
    ) {
        self.url = url
        self.dismissButtonStyle = dismissButtonStyle
    }
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    
    func updateUIViewController(_ viewController: SFSafariViewController, context: Context) {
        viewController.dismissButtonStyle = dismissButtonStyle
    }
}
