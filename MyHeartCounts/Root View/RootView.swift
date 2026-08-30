//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveAccount
import class GroveConsent.ConsentDocument
import GroveFoundation
import GroveOnboarding
import GroveScheduler
import GroveStudy
import GroveViews
import OSLog
import SFSafeSymbols
import SwiftUI


/// The "root" view of the app when logged in and enrolled in a study.
///
/// Displays and manages a `TabView`, with the different tabs in the app.
struct RootView: View {
    // swiftlint:disable attributes
    @Environment(AppState.self) private var appState
    @Environment(Account.self) private var account: Account?
    @Environment(ConsentManager.self) private var consentManager: ConsentManager?
    @Environment(SetupTestEnvironment.self) private var setupTestEnvironment
    @LocalPreference(.onboardingFlowComplete) private var didCompleteOnboarding
    // swiftlint:enable attributes
    
    @State private var consentDocForRenewal: ConsentDocument?
    
    var body: some View {
        ZStack {
            switch setupTestEnvironment.state {
            case .disabled, .done:
                if didCompleteOnboarding, account != nil, !appState.isLoggingOut {
                    TabView()
                        // we might simply want to make every `taskPerformingAnchor` also an `taskContinuationAnchor` at some point?
                        // it's not trivial, though, since we'd also need to make sure that if there's multiple `taskContinuationAnchor`s, only one of them will actually pick up the task...
                        .taskContinuationAnchor()
                        .taskPerformingAnchor()
                        .rootSheetAnchor()
                } else if appState.isLoggingOut {
                    FullScreenProgressView(title: "Logging Out…")
                }
            case .pending, .settingUp:
                FullScreenProgressView(
                    title: "Setting Up Test Environment",
                    subtitle: "\(setupTestEnvironment.desc)"
                )
            case .failure(let error):
                ContentUnavailableView("Error", systemSymbol: .exclamationmarkOctagon, description: Text(error.localizedDescription))
            }
        }
        .trackingScenePhase()
        .modifier(ConsentRenewalSheetModifier())
    }
}


extension RootView {
    private struct TabView: View {
        @LocalPreference(.rootTabSelection)
        private var selectedTab: String // tabId
        
        var body: some View {
            let (tabs, tabIds) = assemble(
                HomeTab.self,
                UpcomingTasksTab.self,
                HeartHealthDashboardTab.self
            )
            SwiftUI.TabView(selection: $selectedTab) {
                tabs
            }
            .tabBarAccessibilityIdentifiersWorkaround(tabIds)
        }
        
        private func makeTab(_ tab: (some RootViewTab).Type) -> some TabContent<String> {
            Tab(String(localized: tab.tabTitle), systemImage: tab.tabSymbol.rawValue, value: tab.tabId) {
                tab.init()
            }
            .accessibilityIdentifier(tab.accessibilityIdentifier)
        }
        
        private func assemble<each Tab: RootViewTab>(
            _ firstTab: (some RootViewTab).Type,
            _ trailingTabs: repeat (each Tab).Type
        ) -> (tabViewContent: some TabContent<String>, tabIds: [String]) {
            // we sadly cannot simply do `TabContentBuilder.buildBlock(repeat makeTab(each tab))`,
            // as the TabContentBuilder currently does not implement a `buildBlock` overload accepting a generic pack.
            var content: AnyTabContent<String> = AnyTabContent(makeTab(firstTab))
            var ids: [String] = [firstTab.accessibilityIdentifier]
            for tab in repeat each trailingTabs {
                content = AnyTabContent(TabContentBuilder.buildBlock(content, makeTab(tab)))
                ids.append(tab.accessibilityIdentifier)
            }
            return (content, ids)
        }
    }
}


extension RootView {
    private struct ConsentRenewalSheetModifier: ViewModifier {
        @Environment(ConsentManager.self)
        private var consentManager: ConsentManager?
        
        func body(content: Content) -> some View {
            if let consentManager {
                @Bindable var consentManager = consentManager
                content.sheet(item: $consentManager.pendingConsentDoc) { doc in
                    ConsentRenewalFlow(document: doc)
                }
            } else {
                content
            }
        }
    }
}


extension RootViewTab {
    fileprivate static var accessibilityIdentifier: String {
        "MHC:Tab:\(tabTitle.localizedString(for: .enUS))"
    }
}


extension LocalPreferenceKeys {
    static let rootTabSelection = LocalPreferenceKey<String>("rootTabSelection", default: HomeTab.tabId)
    
    static let rootTabViewCustomization = LocalPreferenceKey<TabViewCustomization>("rootTabViewCustomization", default: .init())
}


extension ScenePhase: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .background:
            "background"
        case .inactive:
            "inactive"
        case .active:
            "active"
        @unknown default:
            "unknown"
        }
    }
}
