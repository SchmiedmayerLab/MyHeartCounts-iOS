//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import SpeziFoundation
import SwiftUI


struct HealthObservationsLocalPersistenceLayerDebugView: View {
    @Environment(MHCFHIRStore.self) private var fhirStore
    
    @State private var numSamples: Int?
    @State private var numDeletions: Int?
    
    @State private var pendingUploadCountsBySampleType: [String: Int] = [:]
    @State private var pendingDeletionCountsBySampleType: [String: Int] = [:]
    
    @LocalPreference(.numElidedHealthObservationUploads) private var numElidedUploads
    
    var body: some View {
        Form {
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
        guard let db = fhirStore.db else {
            return
        }
        numSamples = try? db.fetchCount(of: MHCFHIRStoreDatabase.Sample.self)
        numDeletions = try? db.fetchCount(of: MHCFHIRStoreDatabase.Deletion.self)
        let fetchSampleTypeCounts = { (type: any MHCFHIRStoreDatabase._TableRecordWithSampleType.Type) -> [String: Int] in
            (try? db.fetchSampleTypeCounts(for: type)) ?? [:]
        }
        pendingUploadCountsBySampleType = fetchSampleTypeCounts(MHCFHIRStoreDatabase.Sample.self)
        pendingDeletionCountsBySampleType = fetchSampleTypeCounts(MHCFHIRStoreDatabase.Deletion.self)
    }
}
