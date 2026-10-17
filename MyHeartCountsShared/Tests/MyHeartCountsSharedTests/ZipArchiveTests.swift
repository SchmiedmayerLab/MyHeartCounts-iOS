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

    private static func unzip(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: unzipPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
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
}
