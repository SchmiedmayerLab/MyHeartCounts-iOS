//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CoreMotion
import Foundation
import MyHeartCountsShared
import SFSafeSymbols
import Spezi
import SpeziFoundation
import SpeziStudyDefinition
import SpeziViews
import SwiftUI


struct TimedWalkingTestSheet: View {
    typealias ResultHandler = @Sendable @MainActor (TimedWalkingTestResult?) async -> Void
    
    private let test: TimedWalkingTestConfiguration
    private let resultHandler: ResultHandler
    
    var body: some View {
        NavigationStack {
            TimedWalkingTestView(test, resultHandler: resultHandler)
        }
        .accessibilityIdentifier("MHC.TimedWalkTestView")
    }
    
    init(_ test: TimedWalkingTestConfiguration, resultHandler: @escaping ResultHandler = { _ in }) {
        self.test = test
        self.resultHandler = resultHandler
    }
}


private struct TimedWalkingTestView: View {
    typealias ResultHandler = TimedWalkingTestSheet.ResultHandler
    
    @Environment(\.openSettingsApp)
    private var openSettingsApp
    
    @Environment(\.openURL)
    private var openUrl
    
    @Environment(\.dismiss)
    private var dismiss
    
    @Environment(WatchConnection.self)
    private var watchManager
    
    @Environment(TimedWalkingTest.self)
    private var timedWalkingTest
    
    private let test: TimedWalkingTestConfiguration
    private let resultHandler: ResultHandler
    
    @State private var viewState: ViewState = .idle
    @State private var showPermissionsErrorSection = false
    
    @State private var didCompleteAtLeastOneTest = false
    @State private var mostRecentResult: TimedWalkingTestResult?
    
    private var testIsRunning: Bool {
        timedWalkingTest.state.isActive
    }
    
    private var testName: LocalizedStringResource {
        if test == .twelveMinuteRunTest {
            return "12-Minute Run Test (Cooper Test)"
        } else {
            let durationInMinutes = (test.duration.totalSeconds / 60).formatted(.number.precision(.fractionLength(0...1)))
            return switch test.kind {
            case .walking:
                "\(durationInMinutes)-Minute Walk Test"
            case .running:
                "\(durationInMinutes)-Minute Run Test"
            }
        }
    }
    
    var body: some View {
        Form {
            sections
                .animation(.default, value: testIsRunning)
        }
        .viewStateAlert(state: $viewState)
        .toolbar(.visible)
        .interactiveDismissDisabled(testIsRunning || viewState == .processing)
        .task {
            switch CMMotionManager.authorizationStatus() {
            case .denied:
                showPermissionsErrorSection = true
            case .authorized, .notDetermined, .restricted:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            if !didCompleteAtLeastOneTest {
                // view is getting dismissed without having performed the action
                Task {
                    await resultHandler(nil)
                }
            }
        }
        .toolbar {
            if !testIsRunning {
                DismissButton()
            }
        }
    }
    
    private var watchParticipatesInTest: Bool {
        // intentionally not checking whether the watch app is reachable, since it might not have been launched yet.
        watchManager.userHasWatch && watchManager.isWatchAppInstalled
    }
    
    @ViewBuilder private var sections: some View {
        PlainSection {
            CenterH {
                Image(systemSymbol: test.kind.symbol)
                    .font(.system(size: 87))
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.accent)
                    .accessibilityHidden(true)
                    .overlay(alignment: .bottomTrailing) {
                        if !testIsRunning, mostRecentResult != nil {
                            ZStack {
                                Image(systemSymbol: .circleFill)
                                    .font(.system(size: 45))
                                    .foregroundStyle(Color(.systemGroupedBackground))
                                    .accessibilityHidden(true)
                                Image(systemSymbol: .checkmarkCircleFill)
                                    .font(.system(size: 40))
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                            }
                            .offset(x: 10, y: 10)
                        }
                    }
            }
        }
        PlainSection {
            VStack(alignment: .leading) {
                Text(testName)
                    .multilineTextAlignment(.leading)
            }
            .font(.title.bold())
            .multilineTextAlignment(.center)
        }
        testActive
        resultsSection
        description
        startButton
    }
    
    @ViewBuilder private var testActive: some View {
        if case let .testActive(session) = timedWalkingTest.state {
            PlainSection {
                Spacer()
                CenterH {
                    VStack(alignment: .center, spacing: 16) {
                        CountdownView(start: session.inProgressResult.startDate, end: session.inProgressResult.endDate)
                        Text("Your \(testName) is in progress.")
                            .multilineTextAlignment(.center)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .toolbar {
                    if session.isRecoveredTest {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                AsyncButton("Cancel", state: $viewState) {
                                    _ = try await timedWalkingTest.stop(discardResult: true)
                                    dismiss()
                                }
                            } label: {
                                Image(systemSymbol: .ellipsisCircle)
                                    .accessibilityLabel("More")
                            }
                        }
                    }
                }
                Spacer()
            }
        }
    }
    
    @ViewBuilder private var resultsSection: some View {
        if !testIsRunning, let result = mostRecentResult {
            Section("Test Complete") {
                LabeledContent("Date", value: result.startDate, format: .dateTime)
                LabeledContent("Steps", value: result.numberOfSteps, format: .number)
                LabeledContent(
                    "Distance",
                    value: Measurement<UnitLength>(value: result.distanceCovered, unit: .meters),
                    format: .measurement(width: .abbreviated)
                )
            }
        }
    }
    
    @ViewBuilder private var description: some View {
        if !testIsRunning {
            PlainSection {
                switch test {
                case .sixMinuteWalkTest:
                    Text("TIMED_WALK_TEST_EXPLAINER_6_MIN_WALK")
                case .twelveMinuteRunTest:
                    Text("TIMED_WALK_TEST_EXPLAINER_12_MIN_RUN")
                default:
                    EmptyView()
                }
                Text("TIMED_WALK_TEST_EXPLAINER_FOOTER")
            }
            if showPermissionsErrorSection {
                ErrorSection(
                    title: "Missing Required Motion Data Access Permission",
                    explanation: "The Timed Walking Test requires read access to Motion and Fitness Data.",
                    actionText: "Open Settings",
                    action: {
                        await openSettingsApp()
                    }
                )
            }
            if watchManager.userHasWatch && !watchManager.isWatchAppInstalled {
                ErrorSection(
                    title: "Companion Watch App Not Installed",
                    explanation: "Installing My Heart Counts on your Apple Watch will allow us to greatly increase the quality of the recorded data.",
                    actionText: "Install on Apple Watch",
                    action: {
                        await openUrl("itms-watchs://")
                    }
                )
            }
        }
    }
    
    @ViewBuilder private var startButton: some View {
        if timedWalkingTest.state == .idle {
            Section {
                AsyncButton(state: $viewState) {
                    do {
                        let result = try await timedWalkingTest.start(test)
                        self.mostRecentResult = result
                        if !didCompleteAtLeastOneTest && result != nil {
                            didCompleteAtLeastOneTest = true
                        }
                        await resultHandler(result)
                    } catch TimedWalkingTest.TestError.unableToStart(.missingSensorPermissions) {
                        showPermissionsErrorSection = true
                    }
                } label: {
                    Text(mostRecentResult == nil ? "Start Test" : "Restart Test")
                        .bold()
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.borderedProminent)
                .disabled(testIsRunning)
                .listRowInsets(.zero)
            }
        }
    }
    
    init(_ test: TimedWalkingTestConfiguration, resultHandler: @escaping ResultHandler) {
        self.test = test
        self.resultHandler = resultHandler
    }
}


extension TimedWalkingTestView {
    private struct CenterH<Content: View>: View {
        @ViewBuilder let content: @MainActor () -> Content
        
        var body: some View {
            HStack(spacing: 0) {
                Spacer()
                content()
                Spacer()
            }
        }
    }


    private struct PlainSection<Content: View>: View {
        private let content: Content
        
        var body: some View {
            content
                .multilineTextAlignment(.leading)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        
        init(@ViewBuilder _ content: () -> Content) {
            self.content = content()
        }
    }


    private struct CountdownView: View {
        let start: Date
        let end: Date

        var body: some View {
            TimelineView(.periodic(from: start, by: 1)) { context in
                let remaining = max(0, Int(end.timeIntervalSince(context.date)))
                let (minutes, seconds) = remaining.quotientAndRemainder(dividingBy: 60)
                Text(String(format: "%d:%02d", minutes, seconds))
                    .font(.system(size: 70, design: .rounded).bold())
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeInOut(duration: 0.2), value: remaining)
            }
        }
    }
    
    
    private struct ErrorSection: View {
        let icon: SFSymbol
        let title: LocalizedStringResource
        let explanation: LocalizedStringResource
        let actionText: LocalizedStringResource
        let action: @MainActor @Sendable () async -> Void
        
        
        var body: some View {
            Section {
                HStack(alignment: .top) {
                    Image(systemSymbol: icon)
                        .accessibilityLabel("Warning Sign")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(title)
                            .font(.headline)
                        Text(explanation)
                            .font(.subheadline)
                    }
                }
                AsyncButton {
                    await action()
                } label: {
                    Text(actionText)
                        .padding(.leading, 29)
                }
            }
        }
        
        
        init(
            icon: SFSymbol = .exclamationmarkTriangle,
            title: LocalizedStringResource,
            explanation: LocalizedStringResource,
            actionText: LocalizedStringResource,
            action: @Sendable @escaping () async -> Void
        ) {
            self.icon = icon
            self.title = title
            self.explanation = explanation
            self.actionText = actionText
            self.action = action
        }
    }
}


extension CMAuthorizationStatus: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .notDetermined:
            "notDetermined"
        case .restricted:
            "restricted"
        case .denied:
            "denied"
        case .authorized:
            "authorized"
        @unknown default:
            "unknown<\(rawValue)>"
        }
    }
}
