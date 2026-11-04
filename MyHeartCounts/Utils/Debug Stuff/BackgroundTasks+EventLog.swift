//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import Synchronization


extension LocalPreferenceKeys {
    /// Where the events lived before ``MHCBackgroundTasks/EventLog``; only read to import them into it.
    static let backgroundTaskEvents = LocalPreferenceKey<[MHCBackgroundTasks.Event]>("backgroundTaskEvents", default: [])
}


extension MHCBackgroundTasks {
    /// The log of background task ``Event``s, stored as one JSON object per line.
    ///
    /// Once the log file outgrows its size limit it replaces `events.previous.jsonl` beside it.
    final class EventLog: Sendable {
        static let shared = EventLog(
            directory: .applicationSupportDirectory.appending(path: "BackgroundTasks", directoryHint: .isDirectory)
        )

        private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        private static var encoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            // `.iso8601` would drop the fractional seconds, which the durations of short tasks depend on.
            encoder.dateEncodingStrategy = .custom { date, dateEncoder in
                var container = dateEncoder.singleValueContainer()
                try container.encode(date.formatted(dateFormat))
            }
            return encoder
        }

        private static var decoder: JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { dateDecoder in
                let container = try dateDecoder.singleValueContainer()
                return try Date(container.decode(String.self), strategy: dateFormat)
            }
            return decoder
        }

        private let fileURL: URL
        private let previousFileURL: URL
        private let maximumFileSize: UInt64
        /// Serializes the accesses of tasks that run concurrently.
        private let file = Mutex(())

        init(directory: URL, maximumFileSize: UInt64 = 1 << 20) {
            fileURL = directory.appending(path: "events.jsonl")
            previousFileURL = directory.appending(path: "events.previous.jsonl")
            self.maximumFileSize = maximumFileSize
        }

        func append(_ events: [Event]) throws {
            let encoder = Self.encoder
            var data = Data()
            for event in events {
                try data.append(encoder.encode(event))
                data.append(0x0A)
            }
            try file.withLock { _ in
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer {
                    try? handle.close()
                }
                let size = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                if size + UInt64(data.count) > maximumFileSize {
                    try? fileManager.removeItem(at: previousFileURL)
                    try fileManager.moveItem(at: fileURL, to: previousFileURL)
                }
            }
        }

        /// The raw log, oldest event first.
        func contents() -> Data {
            file.withLock { _ in
                var contents = (try? Data(contentsOf: previousFileURL)) ?? Data()
                contents.append((try? Data(contentsOf: fileURL)) ?? Data())
                return contents
            }
        }

        /// The logged events, oldest first.
        func events() -> [Event] {
            let decoder = Self.decoder
            return contents()
                .split(separator: 0x0A)
                .compactMap { try? decoder.decode(Event.self, from: $0) }
        }

        /// Moves the events still stored in the preferences into the log.
        ///
        /// The preference is cleared only after the events were written, so a failed import gets retried on the next launch.
        func importLegacyEvents(from prefs: LocalPreferencesStore = .standard) throws {
            let events = prefs[.backgroundTaskEvents]
            guard !events.isEmpty else {
                return
            }
            try append(events)
            prefs[.backgroundTaskEvents] = nil
        }
    }
}
