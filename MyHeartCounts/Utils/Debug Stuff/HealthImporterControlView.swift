//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveAccount
import GroveFoundation
import GroveHealthKit
import GroveHealthKitBulkExport
import GroveStudy
import GroveViews
import MyHeartCountsShared
import SwiftUI


/// A `View` that allows debugging and controling the ``HealthImporter``.
///
/// Primarily intended for internal use.
struct HealthImporterControlView: View {
    @Environment(HistoricalHealthSamplesExportManager.self)
    private var exportManager
    
    @State private var viewState: ViewState = .idle
    
    var body: some View {
        Form {
            AsyncButton("Delete&Reset Session" as String, state: $viewState) {
                try await exportManager.fullyResetSession()
            }
            if let session = exportManager.session {
                section(for: session)
            }
        }
        .navigationTitle("Bulk Export Manager" as String)
        .navigationBarTitleDisplayMode(.inline)
        .viewStateAlert(state: $viewState)
    }
    
    @ViewBuilder
    private func section(for session: any BulkExportSession) -> some View {
        Section {
            Text(session.sessionId.rawValue)
                .monospaced()
            LabeledContent("State" as String) {
                Text(session.state.displayTitle)
            }
            if let progress = session.progress {
                HStack {
                    Text("Progress" as String)
                    Spacer()
                    Text(progress.completion, format: .percent.precision(.fractionLength(0)))
                    ProgressView()
                }
                let batches = progress.activeBatches.sorted(using: [
                    KeyPathComparator(\.sampleType.displayTitle),
                    KeyPathComparator(\.timeRange.lowerBound)
                ])
                ForEach(batches, id: \.self) { batch in
                    LabeledContent(
                        batch.sampleType.displayTitle,
                        value: batch.timeRange.displayText()
                    )
                }
            }
        }
    }
}


extension BulkExportSessionState {
    var displayTitle: String {
        switch self {
        case .paused:
            "paused"
        case .running:
            "running"
        case .completed:
            "completed"
        case .terminated:
            "terminated"
        }
    }
}
