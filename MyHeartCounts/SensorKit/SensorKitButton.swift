//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import SensorKit
import SFSafeSymbols
import SpeziFoundation
import SpeziSensorKit
import SpeziStudy
import SpeziViews
import SwiftUI


struct SensorKitButton: View {
    private struct SensorAuthStatuses {
        var authorized: [any AnySensor] = []
        var denied: [any AnySensor] = []
        var notDetermined: [any AnySensor] = []
        
        init() {
            for sensor in SensorKit.mhcSensors {
                switch sensor.authorizationStatus {
                case .authorized:
                    authorized.append(sensor)
                case .denied:
                    denied.append(sensor)
                case .notDetermined:
                    notDetermined.append(sensor)
                @unknown default:
                    break
                }
            }
        }
        
        mutating func update() {
            self = .init()
        }
    }
    
    // swiftlint:disable attributes
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SensorKit.self) private var sensorKit
    // swiftlint:enable attributes
    
    @State private var viewState: ViewState = .idle
    @State private var isManageSheetPresented = false
    
    @State private var sensorAuthStatuses = SensorAuthStatuses()
    
    var body: some View {
        VStack {
            if isFullyUndetermined {
                LabeledButton(
                    symbol: .waveformPathEcgRectangle,
                    title: "Enable SensorKit",
                    subtitle: "ENABLE_SENSORKIT_SUBTITLE",
                    state: $viewState
                ) {
                    try await enable(SensorKit.mhcSensors)
                }
            } else {
                let subtitle: LocalizedStringResource = if sensorAuthStatuses.authorized.isEmpty {
                    "No data collection active"
                } else {
                    "Data collection enabled for \(sensorAuthStatuses.authorized.count) sensors"
                }
                LabeledButton(
                    symbol: .waveformPathEcgRectangle,
                    title: "Manage SensorKit",
                    subtitle: subtitle,
                    state: $viewState
                ) {
                    isManageSheetPresented = true
                }
                .sheet(isPresented: $isManageSheetPresented) {
                    manageSensorKitSheet
                }
            }
        }
        .viewStateAlert(state: $viewState)
        .onChange(of: scenePhase) { _, scenePhase in
            if scenePhase == .active {
                sensorAuthStatuses.update()
            }
        }
    }
    
    @ViewBuilder private var manageSensorKitSheet: some View {
        NavigationStack {
            SensorKitSheet(viewState: $viewState, enable: self.enable)
        }
    }
    
    private var isFullyUndetermined: Bool {
        sensorAuthStatuses.authorized.isEmpty && sensorAuthStatuses.denied.isEmpty
    }
    
    private func enable(_ sensors: [any AnySensor]) async throws {
        defer {
            sensorAuthStatuses.update()
        }
        let result = try await sensorKit.requestAccess(to: sensors)
        for sensor in result.authorized {
            try await sensor.startRecording()
        }
    }
}


private struct SensorKitSheet: View {
    @Environment(StudyManager.self)
    private var studyManager
    
    @State private var presentedArticle: Article?
    
    @Binding var viewState: ViewState
    let enable: @Sendable ([any AnySensor]) async throws -> Void
    
    var body: some View {
        Form {
            Section {
                Text("ENABLE_SENSORKIT_SUBTITLE")
            }
            Section {
                ForEach(SensorKit.mhcSensors.sorted(using: KeyPathComparator(\.displayName)), id: \.id) { sensor in
                    makeRow(for: sensor)
                }
            } header: {
                Text("Sensors")
            } footer: {
                Text("You can enable or disable individual sensors in the iOS Settings app.")
            }
            Section {
                Button {
                    let fileRef = StudyBundle.FileReference(category: .informationalArticle, filename: "SensorKit", fileExtension: "md")
                    presentedArticle = studyManager.studyEnrollments.first?.studyBundle?
                        .resolve(fileRef, in: studyManager.preferredLocale)
                        .flatMap { Article(contentsOf: $0) }
                } label: {
                    Label("How to Manage SensorKit", systemSymbol: .textPage)
                }
            }
        }
        .navigationTitle("Manage SensorKit")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DismissButton()
            }
        }
        .sheet(item: $presentedArticle) { article in
            ArticleSheet(article: article)
        }
    }
    
    @ViewBuilder
    private func makeRow(for sensor: any AnySensor) -> some View {
        let authStatus = sensor.authorizationStatus
        let shouldDisplay = authStatus == .authorized || SensorKit.mhcSensors.contains { $0.srSensor == sensor.srSensor }
        if shouldDisplay {
            HStack {
                Text(sensor.displayName)
                Spacer()
                switch authStatus {
                case .authorized:
                    Image(systemSymbol: .checkmark)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Active")
                case .notDetermined:
                    AsyncButton("Enable", state: $viewState) {
                        try await enable([sensor])
                    }
                case .denied:
                    Image(systemSymbol: .xmark)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Disabled")
                @unknown default:
                    EmptyView()
                }
            }
        }
    }
}


extension SRAuthorizationStatus: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .notDetermined:
            "notDetermined"
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        @unknown default:
            "unknown<\(rawValue)>"
        }
    }
}
