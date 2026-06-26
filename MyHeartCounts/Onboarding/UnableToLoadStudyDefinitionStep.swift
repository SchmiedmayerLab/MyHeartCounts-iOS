//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SFSafeSymbols
import SpeziViews
import SwiftUI


/// Onboarding step intended to be used to signal to the user that the app was unable to fetch its study definition; most likely due to network connectivity issues.
struct UnableToLoadStudyDefinitionStep: View {
    @Environment(ManagedNavigationStack.Path.self)
    private var onboardingPath
    @Environment(StudyBundleLoader.self)
    private var studyLoader
    
    @State private var viewState: ViewState = .idle
    @State private var viewWidth: CGFloat = 0
    
    var body: some View {
        switch studyLoader.studyBundle {
        case nil, .failure(.noLastUsedFirebaseConfig):
            // the StudyLoader, for whatever reason, hasn't yet loaded the study.
            // it is extremely unlikely, if not even outright impossible, for us to end up in this View
            // with the loader being in this state, but just in case, we treat it as an unknown error and offer a retry functionality.
            makeBody(
                symbol: .xmarkOctagon,
                title: "Failed to Download Study Information",
                message: "The app was unable to load the study, but we're not sure why",
                indicateShouldCheckForUpdates: true
            ) {
                retryButton
            }
        case .failure(.unableToFetchFromServer(let error)):
            makeBody(
                symbol: .wifiSlash,
                title: "Network Issue",
                message: "Make sure your device is connected to the internet and try again",
                additionalErrorInfo: error.localizedDescription,
                indicateShouldCheckForUpdates: false
            ) {
                retryButton
            }
        case .failure(.unableToDecode(let error)):
            makeBody(
                symbol: .xmarkOctagon,
                title: "Failed to Load Study into App",
                message: "The app was able to download the study, but failed to process it.",
                additionalErrorInfo: error.localizedDescription,
                indicateShouldCheckForUpdates: true
            )
        case .failure(.unableToCreateLocalBundle(let error)):
            makeBody(
                symbol: .xmarkOctagon,
                title: "Failed to create local study bundle",
                message: "",
                additionalErrorInfo: error.localizedDescription,
                indicateShouldCheckForUpdates: true
            )
        case .success:
            // we were able to load the study, but somehow ended up in here regardless.
            // this should never happen, but if it does we simply go back to the previous step.
            Color.clear.onAppear {
                onboardingPath.removeLast()
            }
        }
    }
    
    private var retryButton: some View {
        AsyncButton(state: $viewState) {
            // We don't need to handle the result here; the update() call will
            // end up writing its result into the StudyBundleLoader, which is Observable,
            // and will trigger a view update here.
            _ = try? await studyLoader.update()
        } label: {
            Text("Try Again")
                .font(.headline.bold())
                // we need to manually set a min width here, since the parent ContentUnavailableView will otherwise
                // try to make its actions subview as narrow as possible (which we don't want).
                .frame(minWidth: viewWidth / 3, maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.borderedProminent)
    }
    
    @ViewBuilder
    private func makeBody(
        symbol: SFSymbol,
        title: LocalizedStringResource,
        message: LocalizedStringResource,
        additionalErrorInfo: String? = nil,
        indicateShouldCheckForUpdates: Bool,
        @ViewBuilder actions: @escaping @MainActor () -> some View = { EmptyView() }
    ) -> some View {
        HorizontalGeometryReader { width in
            ContentUnavailableView {
                Label(String(localized: title), systemSymbol: symbol)
            } description: {
                Text(message)
                if let additionalErrorInfo {
                    Text(additionalErrorInfo)
                        .font(.footnote)
                }
                if indicateShouldCheckForUpdates {
                    Text("If this issue persists, you might be running an outdated version of the app.")
                }
            } actions: {
                actions()
                if indicateShouldCheckForUpdates {
                    CheckForUpdateButton {
                        Text("Check for App Update")
                    }
                }
            }
            .onChange(of: width, initial: true) { _, width in
                self.viewWidth = width
            }
        }
    }
}
