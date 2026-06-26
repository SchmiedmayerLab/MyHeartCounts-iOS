//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Foundation
import SpeziFoundation
@_spi(Internal)
import SpeziSensorKit
import SpeziViews
import SwiftUI


struct SensorKitSampleSummaries: View {
    @Observable @MainActor
    fileprivate final class SensorInfo {
        let sensor: any AnySensor
        var isProcessing = true
        var error: (any Error)?
        var samplesByDeviceByTimeRange: [Range<Date>: [SensorKit.DeviceInfo: Int]] = [:]
        
        var samplesByTimeRange: [Range<Date>: Int] {
            samplesByDeviceByTimeRange.mapValues { $0.values.reduce(0, +) }
        }
        
        var numTotalSamples: Int {
            samplesByDeviceByTimeRange.reduce(0) {
                $0 + $1.value.values.reduce(0, +)
            }
        }
        
        init(sensor: any AnySensor) {
            self.sensor = sensor
        }
    }
    
    @Environment(SensorKit.self) private var sensorKit
    @State private var sensorInfos: [SensorInfo] = []
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        Form {
            Section {
                AsyncButton("Process" as String, state: $viewState) {
                    await withManagedTaskQueue(limit: 5) { queue in
                        for sensor in SensorKit.allKnownSensors {
                            queue.addTask {
                                await process(sensor, using: sensorInfo(for: sensor))
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(sensorInfos.sorted { $0.numTotalSamples > $1.numTotalSamples }, id: \.sensor.id) { info in
                    row(for: info)
                }
            }
        }
        .navigationTitle("SensorKit Stats" as String)
        .interactiveDismissDisabled(viewState == .processing)
        .navigationBarBackButtonHidden(viewState == .processing)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MemoryUsageIndicator(style: .toolbarItem)
            }
        }
    }
    
    private func sensorInfo(for sensor: any AnySensor) -> SensorInfo {
        if let info = sensorInfos.first(where: { $0.sensor.id == sensor.id }) {
            return info
        } else {
            let info = SensorInfo(sensor: sensor)
            sensorInfos.append(info)
            return info
        }
    }
    
    
    private func row(for info: SensorInfo) -> some View {
        NavigationLink {
            Form {
                let timeRanges = info.samplesByDeviceByTimeRange.keys.sorted(using: KeyPathComparator(\.lowerBound))
                ForEach(timeRanges, id: \.self) { (timeRange: Range<Date>) in
                    VStack {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(timeRange.displayText())
                            }
                            Spacer()
                            Text(info.samplesByTimeRange[timeRange] ?? 0, format: .number)
                                .foregroundStyle(.secondary)
                        }
                        let samplesByDevice = info.samplesByDeviceByTimeRange[timeRange] ?? [:]
                        ForEach(Array(samplesByDevice), id: \.key) { device, numSamples in
                            LabeledContent(device.name, value: numSamples, format: .number)
                                .foregroundStyle(.secondary)
                                .font(.footnote) // footnote?
                        }
                    }
                }
            }
            .navigationTitle(info.sensor.displayName)
        } label: {
            HStack {
                Text(info.sensor.displayName)
                Spacer()
                Text(info.numTotalSamples, format: .number)
                if info.isProcessing {
                    ProgressView()
                }
            }
        }
        .disabled(info.isProcessing)
    }
    
    
    @concurrent
    private func process<S>(_ sensor: some AnySensor<S>, using info: SensorInfo) async {
        await MainActor.run {
            info.isProcessing = true
            info.error = nil
            info.samplesByDeviceByTimeRange = [:]
        }
        let cal = Calendar.current
        do {
            let fetcher = try await AnchoredFetcher(sensor: sensor) { _ in
                // we want to use ephemeral query anchors, bc this fetch is happening outside of the regular anchoring
                .ephemeral()
            }
            for try await (batchInfo, samples) in fetcher {
                let countsByRange: [Range<Date>: Int] = samples.reduce(into: [:]) { result, sample in
                    result[cal.rangeOfDay(for: sample.timeRange.lowerBound), default: 0] += 1
                }
                await MainActor.run {
                    for (range, count) in countsByRange {
                        info.samplesByDeviceByTimeRange[range, default: [:]][batchInfo.device, default: 0] += count
                    }
                }
            }
        } catch {
            await MainActor.run {
                info.error = error
            }
        }
        await MainActor.run {
            info.isProcessing = false
        }
    }
}
