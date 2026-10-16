//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit
import OSLog
import Synchronization


/// An on-device record of the app's HealthKit batch exports, for analysing test runs off the device.
///
/// Written only when the app is launched with `--recordHealthKitExportLog`, which also turns on the exporter's
/// throughput measurement. Every batch appends one JSON object per line to ``fileURL``: a `batch` line with the
/// batch's outcome, then a `throughput` line with the exporter's running totals, which live ingestion and the
/// historical upload share. Every line names the app launch it belongs to, so the analysis can tell runs apart.
///
/// Fetch it from a connected device with `xcrun devicectl device copy from --device <device> --domain-type
/// appDataContainer --domain-identifier edu.stanford.MyHeartCounts --source "Library/Application
/// Support/HealthKitExportLog/export-log.jsonl" --destination export-log.jsonl`.
enum HealthKitExportLog {
    /// The upload path that exported a batch.
    enum Origin: String, Encodable, Sendable {
        case live
        case historical
    }

    /// The log file. Once it outgrows ``maximumFileSize`` it replaces `export-log.previous.jsonl` beside it.
    static let fileURL = URL.applicationSupportDirectory
        .appending(path: "HealthKitExportLog", directoryHint: .isDirectory)
        .appending(path: "export-log.jsonl")

    private static let maximumFileSize = 32 << 20
    /// One identifier per app launch.
    private static let run = UUID()
    /// The hardware model, such as `iPhone18,2`.
    private static let device: String = {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
    /// The app's version and build, such as `3.1.0 (412)`.
    private static let app: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }()
    /// Serializes the appends of batches that finish on different tasks.
    private static let file = Mutex(())

    /// Whether the log is written.
    static var isEnabled: Bool {
        FeatureFlags.recordHealthKitExportLog
    }

    /// The samples of `samples` by HealthKit type identifier.
    static func counts(_ samples: some Collection<some HKSample>) -> [String: Int] {
        samples.reduce(into: [:]) { counts, sample in
            counts[sample.sampleType.identifier, default: 0] += 1
        }
    }

    /// Runs one batch's export and, with the log on, records its outcome and then `exporter`'s throughput.
    static func record(
        _ origin: Origin,
        samples: [String: Int],
        exporter: HealthKitFHIRExporter,
        _ body: () async throws -> HealthKitBatchExport
    ) async throws -> HealthKitBatchExport {
        guard isEnabled else {
            return try await body()
        }
        let start = ContinuousClock.now
        do {
            let export = try await body()
            append(kind: "batch", Batch(origin: origin, samples: samples, duration: .now - start, export: export))
            appendThroughput(of: exporter)
            return export
        } catch {
            append(kind: "batch", Batch(origin: origin, samples: samples, duration: .now - start, error: error))
            appendThroughput(of: exporter)
            throw error
        }
    }

    private static func appendThroughput(of exporter: HealthKitFHIRExporter) {
        if let throughput = exporter.throughput {
            append(kind: "throughput", Throughput(throughput))
        }
    }

    private static func append(kind: String, _ payload: some Encodable) {
        let line = Line(kind: kind, payload: payload)
        file.withLock { _ in
            do {
                var data = try JSONEncoder.exportLog.encode(line)
                data.append(0x0A)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumFileSize {
                    let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.jsonl")
                    _ = try FileManager.default.replaceItemAt(previous, withItemAt: fileURL)
                }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                logger.error("Unable to append to the HealthKit export log: \(error)")
            }
        }
    }
}


extension HealthKitExportLog {
    /// One line: the run and device it was written on, then the payload under its kind.
    private struct Line<Payload: Encodable>: Encodable {
        private enum Keys: String, CodingKey {
            case kind, run, time, device, app
            case operatingSystem = "os"
        }

        private struct PayloadKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        let kind: String
        let payload: Payload

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(HealthKitExportLog.run, forKey: .run)
            try container.encode(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)), forKey: .time)
            try container.encode(HealthKitExportLog.device, forKey: .device)
            try container.encode(ProcessInfo.processInfo.operatingSystemVersionString, forKey: .operatingSystem)
            try container.encode(HealthKitExportLog.app, forKey: .app)
            var payloadContainer = encoder.container(keyedBy: PayloadKey.self)
            try payloadContainer.encode(payload, forKey: PayloadKey(stringValue: kind))
        }
    }

    /// A batch's outcome: what it exported and what Grove refused or warned about, counted by kind, or why it failed.
    private struct Batch: Encodable {
        struct Refusal: Encodable {
            let code: String
            let location: String
            let count: Int
        }

        struct Warning: Encodable {
            let code: String
            let cause: String
            let locations: [String]
            let samples: [String: Int]
        }

        let origin: Origin
        let samples: [String: Int]
        let durationMs: Double
        let outcome: String
        let error: String?
        let refusals: [Refusal]
        let warnings: [Warning]

        init(origin: Origin, samples: [String: Int], duration: Duration, export: HealthKitBatchExport) {
            self.origin = origin
            self.samples = samples
            durationMs = duration.milliseconds
            outcome = "exported"
            error = nil
            let refusals = Dictionary(grouping: export.refusals) { refusal in
                let diagnostic = refusal.reason.diagnostic
                return "\(diagnostic.code)\u{1F}\(diagnostic.location)"
            }
            self.refusals = refusals.map { key, refusals in
                let parts = key.split(separator: "\u{1F}", omittingEmptySubsequences: false)
                return Refusal(code: String(parts[0]), location: String(parts[1]), count: refusals.count)
            }
            .sorted { ($0.code, $0.location) < ($1.code, $1.location) }
            warnings = export.warnings.kinds.map { kind in
                Warning(code: kind.code, cause: kind.cause, locations: kind.locations.sorted(), samples: kind.sampleCountByType)
            }
        }

        init(origin: Origin, samples: [String: Int], duration: Duration, error: any Error) {
            self.origin = origin
            self.samples = samples
            durationMs = duration.milliseconds
            outcome = "failed"
            self.error = String(describing: error)
            refusals = []
            warnings = []
        }
    }

    /// The exporter's running totals since it was created.
    private struct Throughput: Encodable {
        struct Phases: Encodable {
            let plan: Double
            let reserve: Double
            let assemble: Double
            let validate: Double
            let receive: Double
        }

        struct SourceType: Encodable {
            let records: Int
            let graphs: Int
            let refusals: Int
            let bytes: Int
            let durationMs: Double
        }

        let calls: Int
        let records: Int
        let busyMs: Double
        let phasesMs: Phases
        let types: [String: SourceType]

        init(_ throughput: HealthKitFHIRExporter.Throughput) {
            calls = throughput.calls
            records = throughput.records
            busyMs = throughput.busy.milliseconds
            let phases = throughput.phases
            phasesMs = Phases(
                plan: phases.plan.milliseconds,
                reserve: phases.reserve.milliseconds,
                assemble: phases.assemble.milliseconds,
                validate: phases.validate.milliseconds,
                receive: phases.receive.milliseconds
            )
            types = throughput.sourceTypes.mapValues { totals in
                SourceType(
                    records: totals.records,
                    graphs: totals.graphs,
                    refusals: totals.refusals,
                    bytes: totals.bytes,
                    durationMs: totals.duration.milliseconds
                )
            }
        }
    }
}


extension JSONEncoder {
    /// Sorted keys, so a line's fields always appear in the same order.
    fileprivate static var exportLog: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}


extension Duration {
    /// The duration in milliseconds.
    fileprivate var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
