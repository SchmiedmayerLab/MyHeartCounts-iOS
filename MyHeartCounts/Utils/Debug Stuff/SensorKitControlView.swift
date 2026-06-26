//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziFoundation
@_spi(Internal)
import SpeziSensorKit
import SpeziViews
import SwiftUI


struct SensorKitControlView: View {
    private struct QueryAnchorsEntry: Hashable {
        let sensor: any AnySensor
        let deviceProductType: String
        let value: Date
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sensor.id == rhs.sensor.id && lhs.deviceProductType == rhs.deviceProductType && lhs.value == rhs.value
        }
        
        func hash(into hasher: inout Hasher) {
            sensor.hash(into: &hasher)
            hasher.combine(deviceProductType)
            hasher.combine(value)
        }
    }
    
    @Environment(SensorKit.self)
    private var sensorKit
    
    @Environment(SensorKitDataFetcher.self)
    private var dataFetcher
    
    @LocalPreference(.sendSensorKitUploadNotifications)
    private var sendSensorKitNotifications
    
    @State private var viewState: ViewState = .idle
    @State private var queryAnchorValues: [QueryAnchorsEntry] = []
    
    var body: some View {
        Form {
            Section {
                Toggle("Background Upload Notifications" as String, isOn: $sendSensorKitNotifications)
                NavigationLink("Sample Summaries" as String) {
                    SensorKitSampleSummaries()
                }
            }
            Section {
                AsyncButton("Start Recording Data" as String, state: $viewState) {
                    for sensor in SensorKit.mhcSensors {
                        try await sensor.startRecording()
                    }
                }
                AsyncButton("Stop Recording Data" as String, state: $viewState) {
                    for sensor in SensorKit.mhcSensors {
                        try await sensor.stopRecording()
                    }
                }
            }
            queryAnchorsSection
            Section {
                let definitions = SensorKit.mhcSensorUploadDefinitions
                ForEach(Array(definitions.indices), id: \.self) { idx in
                    makeRunFullUploadButton(for: definitions[idx])
                }
            }
        }
        .navigationTitle("SensorKit" as String)
        .viewStateAlert(state: $viewState)
        .task {
            await updateQueryAnchorEntries()
        }
    }
    
    private var queryAnchorsSection: some View {
        Section("Query Anchors" as String) {
            AsyncButton("Update" as String, state: $viewState) {
                await updateQueryAnchorEntries()
            }
            ForEach(queryAnchorValues, id: \.self) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.sensor.displayName)
                        Text(entry.deviceProductType)
                            .font(.footnote)
                    }
                    Spacer()
                    Text(entry.value, format: Date.FormatStyle(date: .numeric, time: .standard).hour(.twoDigits(amPM: .omitted)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            AsyncButton("Reset All" as String, role: .destructive, state: $viewState) {
                @MainActor
                func imp<Sample>(_ sensor: some AnySensor<Sample>) throws {
                    let sensor = Sensor(sensor)
                    try sensorKit.resetQueryAnchors(for: sensor)
                }
                defer {
                    Task {
                        await updateQueryAnchorEntries()
                    }
                }
                for sensor in SensorKit.allKnownSensors {
                    try imp(sensor)
                }
            }
        }
    }
    
    private func makeRunFullUploadButton(for uploadDefinition: any AnyMHCSensorUploadDefinition) -> some View {
        AsyncButton("Perform Full \(uploadDefinition.typeErasedSensor.displayName) Upload" as String, state: $viewState) {
            try await dataFetcher.fetchAndUploadAllSamples(for: uploadDefinition)
        }
    }
    
    private func updateQueryAnchorEntries() async {
        var entries: [QueryAnchorsEntry] = []
        for sensor in SensorKit.mhcSensors {
            guard let anchors = try? await sensorKit.queryAnchorValues(for: sensor) else {
                continue
            }
            for (deviceModel, anchorValue) in anchors {
                entries.append(.init(sensor: sensor, deviceProductType: deviceModel, value: anchorValue))
            }
        }
        self.queryAnchorValues = entries.sorted(using: [
            KeyPathComparator(\.sensor.displayName),
            KeyPathComparator(\.deviceProductType)
        ])
    }
}
