//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import SpeziFoundation
import SpeziViews
import SwiftUI


struct HealthObservationsLocalPersistenceLayerDebugView: View {
    @Environment(HealthUploadStaging.self) private var healthUploadStaging
    
    @State private var numSamples: Int?
    @State private var numDeletions: Int?
    
    @State private var pendingUploadCountsBySampleType: [String: Int] = [:]
    @State private var pendingDeletionCountsBySampleType: [String: Int] = [:]
    
    @LocalPreference(.numElidedHealthObservationUploads) private var numElidedUploads
    
    var body: some View {
        Form {
            Section {
                NavigationLink("Uploader" as String) {
                    UploaderDebugView()
                }
            }
            Section {
                LabeledContent("# samples" as String, value: numSamples?.formatted(.number) ?? "n/a")
                LabeledContent("# deletions" as String, value: numDeletions?.formatted(.number) ?? "n/a")
                LabeledContent("# elided uploads" as String, value: numElidedUploads, format: .number)
            }
            Section("Samples" as String) {
                pendingSamplesSection(for: pendingUploadCountsBySampleType)
            }
            Section("Deletions" as String) {
                pendingSamplesSection(for: pendingDeletionCountsBySampleType)
            }
        }
        .onAppear {
            refreshStats()
        }
        .refreshable {
            refreshStats()
        }
    }
    
    @ViewBuilder
    private func pendingSamplesSection(for data: [String: Int]) -> some View {
        let sortedByCount = data.sorted(using: [
            KeyPathComparator(\.value, order: .reverse),
            KeyPathComparator(\.key)
        ])
        ForEach(Array(sortedByCount.indices), id: \.self) { idx in
            HStack {
                Text(sortedByCount[idx].key)
                Spacer()
                Text(sortedByCount[idx].value, format: .number)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
    }
    
    private func refreshStats() {
        // IDEA: have this auto-update (GRDB provides APIs, but out of scope for now...)
        let sampleTypeStats = try? healthUploadStaging.fetchSampleTypeStats()
        numSamples = sampleTypeStats?.pendingUploads.values.reduce(0, +)
        numDeletions = sampleTypeStats?.pendingDeletions.values.reduce(0, +)
        pendingUploadCountsBySampleType = sampleTypeStats?.pendingUploads ?? [:]
        pendingDeletionCountsBySampleType = sampleTypeStats?.pendingDeletions ?? [:]
    }
}



private struct UploaderDebugView: View {
    @Environment(HealthUploadStagingUploader.self) private var uploader
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        Form {
            AsyncButton("Process" as String, state: $viewState) {
                try await uploader.process()
            }
        }
    }
}
