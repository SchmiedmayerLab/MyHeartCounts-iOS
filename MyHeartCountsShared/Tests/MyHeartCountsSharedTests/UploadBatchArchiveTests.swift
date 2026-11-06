//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import Testing


@Suite
struct UploadBatchArchiveTests {
    private static let start = Date(timeIntervalSince1970: 1_788_000_000.125)

    private static let bundle = Data(#"{"resourceType":"Bundle","entry":[{"fullUrl":"first"},{"fullUrl":"second"}]}"#.utf8)

    /// An archive of two records, one with a recording, as their source adds them.
    private static func archive() throws -> Data {
        var archive = try UploadBatchArchive(source: .sensorKit, sampleTypeId: "com.apple.SensorKit.accelerometer", device: "Watch7,12")
        try archive.addRecord(
            recording: UploadBatchArchive.Recording(name: "first.csv", contents: Data("t,x\n1,2\n".utf8)),
            timeRange: start..<start.addingTimeInterval(60),
            sampleCount: 2
        )
        try archive.addRecord(
            timeRange: start.addingTimeInterval(30)..<start.addingTimeInterval(90),
            sampleCount: 1
        )
        let url = try archive.finalize(bundle: bundle).url
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        return try Data(contentsOf: url)
    }

    @Test
    func readerReadsWhatTheArchiveSumsUp() throws {
        let reader = try UploadBatchArchive.Reader(Self.archive())
        #expect(reader.info.formatVersion == 1)
        #expect(reader.info.source == .sensorKit)
        #expect(reader.info.sampleTypeId == "com.apple.SensorKit.accelerometer")
        #expect(reader.info.device == "Watch7,12")
        #expect(reader.info.numRecords == 2)
        #expect(reader.info.numSamples == 3)
        #expect(reader.info.startDate == Self.start)
        #expect(reader.info.endDate == Self.start.addingTimeInterval(90))
        #expect(try reader.bundle() == Self.bundle)
        #expect(reader.recordingPaths == [UploadBatchArchive.recordingPath(forName: "first.csv")])
        #expect(try reader.recording(at: "recordings/first.csv") == Data("t,x\n1,2\n".utf8))
    }

    @Test
    func aRecordingNameIsWrittenOnce() throws {
        var archive = try UploadBatchArchive(source: .sensorKit, sampleTypeId: "com.apple.SensorKit.accelerometer", device: nil)
        let recording = UploadBatchArchive.Recording(name: "identical.csv", contents: Data("t,x\n1,2\n".utf8))
        try archive.addRecord(recording: recording, timeRange: Self.start..<Self.start.addingTimeInterval(60), sampleCount: 1)
        try archive.addRecord(recording: recording, timeRange: Self.start..<Self.start.addingTimeInterval(60), sampleCount: 1)
        let url = try archive.finalize(bundle: Self.bundle).url
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let reader = try UploadBatchArchive.Reader(contentsOf: url)
        #expect(reader.info.numRecords == 2)
        #expect(reader.recordingPaths == [UploadBatchArchive.recordingPath(forName: "identical.csv")])
    }

    @Test
    func archiveIsDeterministic() throws {
        let first = try Self.archive()
        let second = try Self.archive()
        #expect(first == second)
    }
}
