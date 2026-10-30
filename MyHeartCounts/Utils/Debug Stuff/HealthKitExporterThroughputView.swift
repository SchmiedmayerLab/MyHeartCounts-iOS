//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFoundation
import GroveHealthKitFHIR
import SwiftUI
import UIKit


/// The throughput the app's HealthKit exporter measured, which live ingestion and the historical upload share.
///
/// Measuring is on only when the app is launched with `--measureExporterThroughput`.
struct HealthKitExporterThroughputView: View {
    private enum Status {
        case loading
        case noExporter
        case notMeasuring
        case measured(HealthKitFHIRExporter.Throughput)
    }

    @Environment(MyHeartCountsStandard.self)
    private var standard
    @State private var status: Status = .loading

    var body: some View {
        Form {
            switch status {
            case .loading:
                ProgressView()
            case .noExporter:
                Text("No HealthKit exporter yet: it is built once an account is signed in." as String)
            case .notMeasuring:
                Text("Measuring is off. Launch the app with --measureExporterThroughput to measure." as String)
            case .measured(let throughput):
                measured(throughput)
            }
        }
        .navigationTitle("Exporter Throughput" as String)
        .task {
            while !Task.isCancelled {
                status = await currentStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func secondsValue(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", secondsValue(duration))
    }

    private static func rate(_ records: Int, in duration: Duration) -> String {
        let seconds = secondsValue(duration)
        return seconds > 0 ? Int((Double(records) / seconds).rounded()).formatted() : "–"
    }

    private static func percent(_ part: Duration, of total: Duration) -> String {
        let total = secondsValue(total)
        return total > 0 ? String(format: "%.1f%%", secondsValue(part) / total * 100) : "–"
    }

    private static func summary(_ totals: HealthKitFHIRExporter.Throughput.SourceTypeTotals) -> String {
        let perRecord = totals.records > 0 ? String(format: "%.2f ms/record", secondsValue(totals.duration) / Double(totals.records) * 1000) : "–"
        let perGraph = totals.graphs > 0 ? String(format: "%.1f KB/graph", Double(totals.bytes) / Double(totals.graphs) / 1024) : "–"
        return "\(totals.records) records · \(totals.graphs) graphs · \(totals.refusals) refusals · \(perRecord) · \(perGraph)"
    }

    @ViewBuilder
    private func measured(_ throughput: HealthKitFHIRExporter.Throughput) -> some View {
        Section("Totals" as String) {
            LabeledContent("Records" as String, value: throughput.records.formatted())
            LabeledContent("Export calls" as String, value: throughput.calls.formatted())
            LabeledContent("Busy" as String, value: Self.seconds(throughput.busy))
            LabeledContent("Records/s (busy)" as String, value: Self.rate(throughput.records, in: throughput.busy))
            LabeledContent("Records/s (exporter time)" as String, value: Self.rate(throughput.records, in: throughput.phases.exporter))
        }
        Section("Phases" as String) {
            let phases = throughput.phases
            let total = phases.exporter + phases.receive
            phaseRow("Plan", phases.plan, of: total)
            phaseRow("Reserve", phases.reserve, of: total)
            phaseRow("Assemble", phases.assemble, of: total)
            phaseRow("Validate", phases.validate, of: total)
            phaseRow("Receive (caller)", phases.receive, of: total)
        }
        Section("Source Types" as String) {
            let types = throughput.sourceTypes.sorted { lhs, rhs in
                lhs.value.records != rhs.value.records ? lhs.value.records > rhs.value.records : lhs.key < rhs.key
            }
            ForEach(types, id: \.key) { type, totals in
                VStack(alignment: .leading) {
                    Text(type)
                        .font(.footnote.monospaced())
                    Text(Self.summary(totals) as String)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section {
            Button("Copy Report" as String) {
                UIPasteboard.general.string = throughput.description
            }
        }
    }

    private func phaseRow(_ name: String, _ duration: Duration, of total: Duration) -> some View {
        LabeledContent(name, value: "\(Self.seconds(duration)) · \(Self.percent(duration, of: total))")
    }

    private func currentStatus() async -> Status {
        let ledger = await standard.fhirExchangeLedger
        let accountDataGeneration = LocalPreferencesStore.standard[.accountDataGeneration]
        guard let exporter = try? ledger.healthKitExporter(forBatchOf: accountDataGeneration) else {
            return .noExporter
        }
        guard let throughput = exporter.throughput else {
            return .notMeasuring
        }
        return .measured(throughput)
    }
}
