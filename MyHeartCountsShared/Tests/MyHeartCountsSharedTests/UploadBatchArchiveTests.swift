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

    /// A record's recordings, in memory or in files, are each written once, under the path the Bundle states, and read back
    /// exactly; a file-backed recording is stored as it is.
    @Test
    func recordingsFromFilesAndMemoryRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x42, count: 10_000)
        let image = Data(repeating: 0x7F, count: 2_048)
        try pdf.write(to: directory.appending(component: "note.pdf"))
        try image.write(to: directory.appending(component: "scan.png"))
        let pdfRecording = UploadBatchArchive.Recording(name: "note.pdf", fileAt: directory.appending(component: "note.pdf"))
        let imageRecording = UploadBatchArchive.Recording(name: "scan.png", fileAt: directory.appending(component: "scan.png"))
        let csvRecording = UploadBatchArchive.Recording(name: "values.csv", contents: Data("t,x\n1,2\n".utf8))

        var archive = try UploadBatchArchive(source: .healthKit, sampleTypeId: "HKClinicalTypeIdentifierClinicalNoteRecord", device: nil)
        try archive.addRecord(
            recordings: [pdfRecording, imageRecording],
            timeRange: Self.start..<Self.start,
            sampleCount: 1
        )
        // A second record referencing a file the first one already wrote, and a recording in memory.
        try archive.addRecord(
            recordings: [pdfRecording, csvRecording],
            timeRange: Self.start..<Self.start.addingTimeInterval(1),
            sampleCount: 1
        )
        let url = try archive.finalize(bundle: Self.bundle).url
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let reader = try UploadBatchArchive.Reader(contentsOf: url)
        #expect(reader.info.source == .healthKit)
        #expect(reader.info.numRecords == 2)
        #expect(reader.recordingPaths == ["recordings/note.pdf", "recordings/scan.png", "recordings/values.csv"])
        #expect(try reader.recording(at: "recordings/note.pdf") == pdf)
        #expect(try reader.recording(at: "recordings/scan.png") == image)
        #expect(try reader.recording(at: "recordings/values.csv") == Data("t,x\n1,2\n".utf8))
        let entries = try ZipArchive.Reader(contentsOf: url).entries
        #expect(entries.first { $0.path == "recordings/note.pdf" }?.compression == ZipArchive.Compression.none)
    }

    @Test
    func archiveIsDeterministic() throws {
        let first = try Self.archive()
        let second = try Self.archive()
        #expect(first == second)
    }
}
