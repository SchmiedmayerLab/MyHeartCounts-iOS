//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order attributes

import Foundation
import SFSafeSymbols
import SpeziAccount
import SpeziFoundation
import SpeziLocalStorage
import SpeziStudy
import SpeziStudyDefinition
import SpeziViews
import SwiftUI
import UIKit
import XCTSpeziNotificationsUI


struct DebugForm: View {
    var body: some View {
        DebugFormImpl()
            .taskPerformingAnchor()
    }
}


private struct DebugFormImpl: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(StudyManager.self) private var studyManager
    @Environment(DemoSetup.self) private var demoSetup
    @Environment(LocalNotifications.self) private var localNotifications
    @LocalPreference(.sendHealthSampleUploadNotifications) private var healthUploadNotifications
    @LocalPreference(.rejectedHomeTabPromptedActions) private var rejectedHomeTabActions
    @PerformTask private var performTask
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        Form { // swiftlint:disable:this closure_body_length
            Section {
                DemographicsButton(allowDragToDismiss: false)
            }
            Section {
                MemoryUsageIndicator(style: .labeledContent)
            }
            Section("Notifications") {
                Toggle(isOn: $healthUploadNotifications) {
                    Label("Live Health Upload Notifications" as String, systemSymbol: .arrowUpHeart)
                        .foregroundStyle(colorScheme.textLabelForegroundStyle)
                }
                NavigationLink(symbol: .appBadge, "Notifications Status" as String) {
                    NotificationsManagerControlView()
                }
                NavigationLink(symbol: .bellBadge, "Scheduled Local Notifications" as String) {
                    PendingNotificationsList()
                }
                NavigationLink(symbol: .serverRack, "Remote Notifications" as String) {
                    DebugRemoteNotificationStuff()
                }
                if FeatureFlags.isTakingDemoScreenshots {
                    AsyncButton("Send Demo Nudge Notification" as String, state: $viewState) {
                        let nudge = DailyNudge.Nudge.demoNudge
                        try await localNotifications.send(
                            title: nudge.title,
                            body: nudge.message,
                            date: .now.addingTimeInterval(5)
                        )
                    }
                }
            }
            Section {
                NavigationLink(symbol: .calendar, "Health Data Bulk Upload" as String) {
                    HealthImporterControlView()
                }
                NavigationLink("Health Observations Local Persistence" as String) {
                    HealthObservationsLocalPersistenceLayerDebugView()
                }
                NavigationLink("SensorKit" as String) {
                    SensorKitControlView()
                }
                NavigationLink("Background Tasks Log" as String) {
                    MHCBackgroundTasks.EventsView()
                }
                NavigationLink("File Upload Queue" as String) {
                    FileUploadInsights()
                }
                NavigationLink("Scheduler Stats" as String) {
                    SchedulerStats()
                }
                NavigationLink("File Browser" as String) {
                    FileBrowser(url: .documentsDirectory)
                }
            }
            Section("Other" as String) {
                LabeledContent("size(AS/firestore)" as String, value: { () -> String in
                    let url = URL.applicationSupportDirectory.appendingPathComponent("firestore", isDirectory: true)
                    if let size = try? FileManager.default.directorySize(at: url) {
                        return size.formatted(.byteCount(style: .file))
                    } else {
                        return "n/a"
                    }
                }())
                Button("Reset rejected HomeTab actions" as String) {
                    rejectedHomeTabActions = []
                }
                Button {
                    performTask(.timedWalkTest(.sixMinuteWalkTest), context: nil)
                } label: {
                    Label("Timed Walking Test" as String, systemSymbol: .figureWalk)
                }
                // intended for the UI tests to have some data here...
                AddSleepSessionsButton(viewState: $viewState)
                answerQuestionnaireRow
                AsyncButton("Add Demo Data" as String, state: $viewState) {
                    try await demoSetup.addDemoData()
                }
            }
            Section {
                Button("Replace Root View Controller" as String, role: .destructive) {
                    // The idea here is that discarding the root view controller should deallocate all our resources.
                    // We can then launch Xcode's memory graph debugger, and anything that's still in the left sidebar is leaked.
                    replaceRootVC()
                }
            }
        }
        .navigationTitle("Debug Options" as String)
        .navigationBarTitleDisplayMode(.inline)
        .viewStateAlert(state: $viewState)
    }
    
    private var answerQuestionnaireRow: some View {
        Menu {
            let options = ["HeartRisk", "Diet", "NicotineExposure", "WHO5"]
            ForEach(options, id: \.self) { option in
                Button(option) {
                    let fileRef = StudyBundle.FileReference(category: .questionnaire, filename: option, fileExtension: "json")
                    if let questionnaire = studyManager.studyEnrollments.first?.studyBundle?.questionnaire(for: fileRef, in: .enUS) {
                        performTask(.answerQuestionnaire(questionnaire), context: nil)
                    }
                }
            }
        } label: {
            HStack {
                Text("Answer Questionnaire" as String)
                Spacer()
                Image(systemSymbol: .chevronUpChevronDown)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }
    
    private func replaceRootVC() {
        guard let window = UIApplication.shared
            .connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow }) else {
            return
        }
        window.rootViewController = UIViewController()
    }
}


extension DebugForm {
    // periphery:ignore - occasionally useful
    struct EnrollmentTestingView: View {
        @Environment(Account.self)
        private var account
        @Environment(StudyManager.self)
        private var studyManager
        @State private var viewState: ViewState = .idle
        
        let refresh: @MainActor () -> Void
        
        var body: some View {
            VStack {
                AsyncButton("Enroll", state: $viewState) {
                    guard let enrollmentDate = account.details?.dateOfEnrollment else {
                        throw NSError(domain: "edu.stanford.MHC", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "No Enrollment Date"
                        ])
                    }
                    let studyBundle = try await StudyBundleLoader.shared.update()
                    try await studyManager.enroll(in: studyBundle, enrollmentDate: enrollmentDate - Duration.days(5).timeInterval)
                    refresh()
                }
                AsyncButton("Unenroll", state: $viewState) {
                    guard let enrollment = studyManager.studyEnrollments.first else {
                        return
                    }
                    try await studyManager.unenroll(from: enrollment)
                    refresh()
                }
            }
            .viewStateAlert(state: $viewState)
        }
    }
}


extension Locale {
    static let enUS = Locale(identifier: "en-US")
    // periphery:ignore - API
    static let enDE = Locale(identifier: "en-DE")
}
