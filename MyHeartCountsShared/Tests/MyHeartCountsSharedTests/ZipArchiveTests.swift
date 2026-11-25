//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCountsShared
import Testing


private let unzipPath = "/usr/bin/unzip"


@Suite
struct ZipArchiveTests {
    /// Text that deflates well, binary noise that does not, an empty file, and a nested UTF-8 path.
    private static let entries: [ZipArchive.Entry] = [
        .init(path: "bundles/record.json", contents: Data(String(repeating: #"{"resourceType":"Bundle"},"#, count: 200).utf8)),
        .init(path: "recordings/record.bin", contents: noise(byteCount: 4_096)),
        .init(path: "empty.txt", contents: Data()),
        .init(path: "nested/dir/größe.csv", contents: Data("a,b\n1,2\n".utf8))
    ]

    /// Bytes no compressor can shrink, the same on every run.
    private static func noise(byteCount: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return Data((0..<byteCount).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        })
    }

    /// A temporary file, removed once `body` returns.
    private static func withTemporaryFile<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let url = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        return try body(url)
    }

    /// The bytes of the archive of `entries`, added in order under `compression`.
    private static func archive(_ entries: [ZipArchive.Entry], compression: ZipArchive.Compression = .deflate) throws -> Data {
        try withTemporaryFile { url in
            var archive = try ZipArchive(writingTo: url)
            for entry in entries {
                try archive.addEntry(at: entry.path, contents: entry.contents, compression: compression)
            }
            try archive.finalize()
            return try Data(contentsOf: url)
        }
    }

    /// The bytes of the archive `body` writes to a fresh archive created under `limits`, then finalizes.
    private static func archive(limits: ZipArchive.Limits, _ body: (inout ZipArchive) throws -> Void) throws -> Data {
        try withTemporaryFile { url in
            var archive = try ZipArchive(writingTo: url, limits: limits)
            try body(&archive)
            try archive.finalize()
            return try Data(contentsOf: url)
        }
    }

    /// `contents` in a temporary file, which `body` gets the URL of; the file is removed once `body` returns.
    private static func withFile<Result>(holding contents: Data, _ body: (URL) throws -> Result) throws -> Result {
        let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try contents.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        return try body(url)
    }

    /// The error adding an empty entry at `path` to `archive` throws, if any.
    private static func error(addingEntryAt path: String, to archive: inout ZipArchive) -> ZipArchive.ZipError? {
        do {
            try archive.addEntry(at: path, contents: Data())
            return nil
        } catch {
            return error as? ZipArchive.ZipError
        }
    }

    /// The compression method the local header at the start of a single-entry archive states.
    private static func methodOfOnlyEntry(in archive: Data) -> UInt16 {
        UInt16(archive[archive.startIndex + 8]) | UInt16(archive[archive.startIndex + 9]) << 8
    }

    @Test
    func crc32MatchesTheKnownAnswer() {
        let crc32 = ZipArchive.crc32
        #expect(crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(crc32(Data()) == 0)
    }

    @Test
    func archiveIsDeterministic() throws {
        let first = try Self.archive(Self.entries)
        let second = try Self.archive(Self.entries)
        #expect(first == second)
        #expect(try first != Self.archive(Self.entries.reversed()))
    }

    @Test
    func entryIsDeflatedOnlyWhenThatMakesItSmaller() throws {
        let text = try Self.archive([Self.entries[0]])
        let noise = try Self.archive([Self.entries[1]])
        #expect(Self.methodOfOnlyEntry(in: text) == 8)
        #expect(Self.methodOfOnlyEntry(in: noise) == 0)
        #expect(text.count < Self.entries[0].contents.count)
    }

    /// An entry added with Zstandard compression is compressed with it where that makes it smaller, and stored otherwise.
    @Test
    func entryIsCompressedWithZstdOnlyWhenThatMakesItSmaller() throws {
        let text = try Self.archive([Self.entries[0]], compression: .zstd)
        let noise = try Self.archive([Self.entries[1]], compression: .zstd)
        #expect(Self.methodOfOnlyEntry(in: text) == 93)
        #expect(Self.methodOfOnlyEntry(in: noise) == 0)
        #expect(try ZipArchive.entries(in: Self.archive(Self.entries, compression: .zstd)) == Self.entries)
    }

    /// An entry added without compression is stored as is, even where deflating would have made it smaller.
    @Test
    func entryAddedWithoutCompressionIsStored() throws {
        let text = try Self.archive([Self.entries[0]], compression: .none)
        #expect(Self.methodOfOnlyEntry(in: text) == 0)
        #expect(text.count > Self.entries[0].contents.count)
    }

    @Test
    func emptyArchiveIsOnlyItsEndRecord() throws {
        let archive = try Self.archive([])
        #expect(archive == Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)))
    }

    /// A path the archive cannot hold is rejected before anything is written, and the archive stays usable.
    @Test
    func invalidPathsAreRejected() throws {
        try Self.withTemporaryFile { url in
            var archive = try ZipArchive(writingTo: url)
            for path in ["", "/absolute", "a//b", "a/./b", "../escape", "directory/", #"back\slash"#] {
                #expect(Self.error(addingEntryAt: path, to: &archive) == .invalidPath(path))
            }
            try archive.addEntry(at: "a", contents: Data())
            #expect(Self.error(addingEntryAt: "a", to: &archive) == .duplicatePath("a"))
            try archive.finalize()
            #expect(try Data(contentsOf: url) == Self.archive([.init(path: "a", contents: Data())]))
        }
    }

    /// An archive dropped before it is finalized removes its file rather than leave an incomplete archive behind.
    @Test
    func unfinalizedArchiveRemovesItsFile() throws {
        try Self.withTemporaryFile { url in
            do {
                var archive = try ZipArchive(writingTo: url)
                try archive.addEntry(at: "a", contents: Data("a".utf8))
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}


#if os(macOS) || os(Linux)
extension ZipArchiveTests {
    fileprivate static func unzip(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: unzipPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    
    /// An independent extractor accepts the archive and recovers every entry's exact bytes.
    ///
    /// The archive is extracted as a whole: `Process` passes its arguments in their file system representation, whose
    /// decomposed Unicode would not match the entry's precomposed UTF-8 path.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: unzipPath)))
    func unzipExtractsEveryEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let archive = directory.appending(component: "archive.zip")
        let extracted = directory.appending(component: "extracted")
        try Self.archive(Self.entries).write(to: archive)

        #expect(try Self.unzip(["-t", "-qq", archive.path]) == 0)
        #expect(try Self.unzip(["-qq", archive.path, "-d", extracted.path]) == 0)
        for entry in Self.entries {
            #expect(try Data(contentsOf: extracted.appending(path: entry.path)) == entry.contents, "\(entry.path)")
        }
    }
}
#endif


extension ZipArchiveTests {
    @Test
    func entriesRoundTrip() throws {
        #expect(try ZipArchive.entries(in: Self.archive(Self.entries)) == Self.entries)
        #expect(try ZipArchive.entries(in: Self.archive([])).isEmpty)
    }

    /// A reader lists an archive's entries from its central directory, and reads any one entry's contents on its own.
    @Test
    func readerListsEntriesAndReadsEachOnItsOwn() throws {
        try Self.withTemporaryFile { url in
            try Self.archive(Self.entries).write(to: url)
            let reader = try ZipArchive.Reader(contentsOf: url)
            #expect(reader.entries.map(\.path) == Self.entries.map(\.path))
            #expect(reader.entries.map(\.size) == Self.entries.map(\.contents.count))
            #expect(reader.entries.map(\.compression) == [.deflate, .none, .none, .none])
            let last = try #require(reader.entries.last)
            #expect(try reader.contents(of: last) == Self.entries.last?.contents)
        }
    }

    @Test
    func corruptedContentsFailTheirChecksum() throws {
        let entry = Self.entries[1]
        var archive = try Self.archive([entry])
        // The stored contents follow the 30-byte local header and the entry's path.
        archive[archive.startIndex + 30 + entry.path.utf8.count] ^= 0xFF
        #expect(throws: ZipArchive.ZipError.malformedArchive) {
            try ZipArchive.entries(in: archive)
        }
    }

    @Test
    func truncatedArchiveIsMalformed() throws {
        let archive = try Self.archive(Self.entries)
        #expect(throws: ZipArchive.ZipError.malformedArchive) {
            try ZipArchive.entries(in: archive.dropLast(1))
        }
    }

    /// An entry larger than the reader's limit is refused before it is decompressed, as are entries larger in total.
    @Test
    func entriesBeyondTheSizeLimitAreRefused() throws {
        let entry = Self.entries[0]
        let reader = try ZipArchive.Reader(Self.archive([entry]), maximumEntrySize: entry.contents.count - 1)
        let info = try #require(reader.entries.first)
        #expect(throws: ZipArchive.ZipError.sizeLimitExceeded(path: entry.path)) {
            try reader.contents(of: info)
        }
        #expect(throws: ZipArchive.ZipError.sizeLimitExceeded(path: Self.entries[1].path)) {
            try ZipArchive.entries(in: Self.archive(Self.entries), maximumTotalSize: entry.contents.count)
        }
    }

    /// The end record is the one its comment ends the archive after, not an end-record signature within that comment.
    @Test
    func endRecordSignatureWithinTheCommentIsSkipped() throws {
        var archive = try Self.archive(Self.entries)
        // A comment that holds a would-be end record of an empty archive, followed by one more byte.
        let comment = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18) + [0x41])
        archive[archive.endIndex - 2] = UInt8(comment.count)
        archive.append(comment)
        #expect(try ZipArchive.entries(in: archive) == Self.entries)
    }

    /// Two entries under one path make an archive malformed, whichever of them a reader would pick.
    @Test
    func duplicatePathsAreRefused() throws {
        let archive = try Self.archive([
            .init(path: "entry-one", contents: Data("1".utf8)),
            .init(path: "entry-two", contents: Data("2".utf8))
        ])
        let duplicated = archive.replacing(Data("entry-two".utf8), with: Data("entry-one".utf8))
        #expect(throws: ZipArchive.ZipError.duplicatePath("entry-one")) {
            try ZipArchive.Reader(duplicated)
        }
    }

    /// A file streamed into an entry spans several read chunks, is stored as it is, and makes exactly the bytes adding
    /// the same contents from memory without compression makes.
    @Test
    func fileEntryIsStreamedAndStored() throws {
        // More than two of the archive's 1 MiB read chunks, so the CRC-32 runs across chunk boundaries.
        let contents = Self.noise(byteCount: (5 << 20) / 2) + Data(String(repeating: "text", count: 1_000).utf8)
        let streamed = try Self.withFile(holding: contents) { file in
            try Self.archive(limits: ZipArchive.Limits()) { archive in
                try archive.addEntry(at: "recordings/file.pdf", contentsOf: file)
            }
        }
        let fromMemory = try Self.archive([.init(path: "recordings/file.pdf", contents: contents)], compression: .none)
        #expect(streamed == fromMemory)
        #expect(Self.methodOfOnlyEntry(in: streamed) == 0)
        let reader = try ZipArchive.Reader(streamed)
        let entry = try #require(reader.entries.first)
        #expect(entry.crc32 == ZipArchive.crc32(contents))
        #expect(try reader.contents(of: entry) == contents)
    }

    /// A file that can't be read throws before anything is written, so the archive stays usable and unchanged.
    @Test
    func unreadableFileLeavesTheArchiveUsable() throws {
        let missing = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let archive = try Self.archive(limits: ZipArchive.Limits()) { archive in
            #expect(throws: (any Error).self) {
                try archive.addEntry(at: "missing.pdf", contentsOf: missing)
            }
            try archive.addEntry(at: "a", contents: Data("a".utf8))
        }
        #expect(try archive == Self.archive([.init(path: "a", contents: Data("a".utf8))]))
    }

    /// Where every size and offset is written with ZIP64 fields, as an archive past 4 GiB writes them, every entry still
    /// reads back exactly, compressed, stored or streamed, and an independent extractor accepts the archive.
    @Test
    func zip64SizesAndOffsetsRoundTrip() throws {
        let streamedContents = Self.noise(byteCount: 3_000)
        let archive = try Self.withFile(holding: streamedContents) { file in
            try Self.archive(limits: ZipArchive.Limits(field: 0)) { archive in
                for entry in Self.entries {
                    try archive.addEntry(at: entry.path, contents: entry.contents)
                }
                try archive.addEntry(at: "recordings/streamed.bin", contentsOf: file)
            }
        }
        let expected = Self.entries + [.init(path: "recordings/streamed.bin", contents: streamedContents)]
        #expect(try ZipArchive.entries(in: archive) == expected)
        let reader = try ZipArchive.Reader(archive)
        #expect(reader.entries.map(\.size) == expected.map(\.contents.count))
        #if os(macOS) || os(Linux)
        if FileManager.default.isExecutableFile(atPath: unzipPath) {
            let status = try Self.withFile(holding: archive) { url in
                try Self.unzip(["-t", "-qq", url.path])
            }
            #expect(status == 0)
        }
        #endif
    }

    /// Where the entry count is too large for the end record, as past 65,535 entries, a ZIP64 end record states it.
    @Test
    func zip64EntryCountRoundTrips() throws {
        let entries = (0..<5).map { ZipArchive.Entry(path: "entry-\($0)", contents: Data("\($0)".utf8)) }
        let archive = try Self.archive(limits: ZipArchive.Limits(entryCount: 3)) { archive in
            for entry in entries {
                try archive.addEntry(at: entry.path, contents: entry.contents)
            }
        }
        // The end record defers its entry counts to the ZIP64 end record.
        #expect(archive[archive.endIndex - 14] == 0xFF && archive[archive.endIndex - 13] == 0xFF)
        #expect(try ZipArchive.entries(in: archive) == entries)
        // The same entries without ZIP64 make another, shorter archive that reads back the same.
        let classic = try Self.archive(entries)
        #expect(classic.count < archive.count)
        #expect(try ZipArchive.entries(in: classic) == entries)
    }

    /// A local header that describes its entry differently from the central directory makes the entry malformed.
    @Test
    func localHeaderMustMatchTheCentralDirectory() throws {
        var archive = try Self.archive([.init(path: "entry-one", contents: Data("1".utf8))])
        // The local header, which comes first, states the path right after its 30 fixed bytes.
        archive.replaceSubrange((archive.startIndex + 30)..<(archive.startIndex + 39), with: Data("entry-two".utf8))
        let reader = try ZipArchive.Reader(archive)
        let entry = try #require(reader.entries.first)
        #expect(throws: ZipArchive.ZipError.malformedArchive) {
            try reader.contents(of: entry)
        }
    }
}
