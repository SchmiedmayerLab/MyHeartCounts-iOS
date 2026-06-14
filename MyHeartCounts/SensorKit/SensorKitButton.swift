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
    @Environment(SensorKit.self)
    private var sensorKit
    
    @State private var viewState: ViewState = .idle
    @State private var isManageSheetPresented = false
    
    @SensorAccessPermissions private var sensorAccessPermissions
    
    var body: some View {
        AsyncButton(state: $viewState) {
            if sensorAccessPermissions.isFullyUndetermined {
                try await enable(SensorKit.mhcSensors)
            } else {
                isManageSheetPresented = true
            }
        } label: {
            if sensorAccessPermissions.isFullyUndetermined {
                enableLabel
            } else {
                manageLabel
            }
        }
        .viewStateAlert(state: $viewState)
        .sheet(isPresented: $isManageSheetPresented) {
            NavigationStack {
                SensorKitSheet(viewState: $viewState, enable: enable)
            }
        }
    }
    
    /// The "Enable SensorKit" label
    private var enableLabel: some View {
        makeLabel(title: "Enable SensorKit", subtitle: "ENABLE_SENSORKIT_SUBTITLE")
    }
    
    /// The "Manage SensorKit" label
    private var manageLabel: some View {
        let subtitle: LocalizedStringResource = switch sensorAccessPermissions.numAuthorized {
        case 0:
            "No data collection active"
        case let count:
            "Data collection enabled for \(count, format: .number) sensors"
        }
        return makeLabel(title: "Manage SensorKit", subtitle: subtitle)
    }
    
    private func makeLabel(title: LocalizedStringResource, subtitle: LocalizedStringResource) -> some View {
        VStack(alignment: .listRowSeparatorLeading) {
            Text(title)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.textLabel)
    }
    
    private func enable(_ sensors: [any AnySensor]) async throws {
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
        .navigationTitle("SensorKit")
        .navigationBarTitleDisplayMode(.inline)
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
