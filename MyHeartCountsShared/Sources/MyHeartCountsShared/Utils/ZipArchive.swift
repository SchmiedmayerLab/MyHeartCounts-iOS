//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_length

public import Foundation
import GroveFoundation
#if canImport(zlib)
import zlib
#else
import MyHeartCountsCZlib
#endif


/// A ZIP archive, written to a file entry by entry.
///
/// Unlike a tar stream, a ZIP archive compresses each entry on its own and ends with a central directory that locates
/// every entry, so a reader can open one entry without decompressing any other.
///
/// Each entry's header and contents are written to the file as the entry is added, so that only the entry being added is
/// held in memory; ``finalize()`` then appends the central directory, without which the file is no valid archive. An
/// archive that is not finalized, or whose writing failed, removes its file, so an incomplete archive is never left
/// behind.
///
/// The implementation covers the subset needed to package a set of files: regular files, stored, deflated or compressed
/// with Zstandard, without encryption or data descriptors. An entry, an offset or an entry count too large for the
/// classic fields is written with ZIP64 extensions, so an archive has no size limit; the only extra field written is
/// ZIP64's. Writing is deterministic — entries are emitted in the order they are added, all under the same fixed
/// timestamp — so the same entries always produce the same bytes. Each entry is stored as is or compressed, as the
/// ``Compression`` it is added with says; an entry streamed from a file (``addEntry(at:contentsOf:)``) is stored.
///
/// ``entries(in:)`` reads an archive back.
public struct ZipArchive: ~Copyable {
    /// A single file in a ZIP archive.
    public struct Entry: Hashable, Sendable {
        /// The entry's path within the archive, relative to its root, with `/` separating its components.
        public var path: String
        /// The file contents.
        public var contents: Data

        public init(path: String, contents: Data) {
            self.path = path
            self.contents = contents
        }
    }

    public enum ZipError: Error, Equatable {
        /// An entry path is empty or absolute, contains a backslash, or has an empty, `.` or `..` component.
        case invalidPath(String)
        /// Two entries share a path.
        case duplicatePath(String)
        /// An entry's path is longer than 65,535 bytes, which no ZIP field can state.
        case tooLarge
        /// A file streamed into an entry changed while it was being read: it held another number of bytes than it did
        /// when its entry was started.
        case sourceChanged(path: String)
        /// Compressing an entry's contents failed.
        case compressionFailed
        /// An earlier write to the archive's file failed, leaving it without a consistent structure.
        case writeFailed
        /// The archive could not be parsed, or an entry's contents do not match its stored size or CRC-32.
        case malformedArchive
        /// Reading the entry at `path` would exceed the reader's size limit.
        case sizeLimitExceeded(path: String)
        /// An entry is encrypted, or compressed with a method other than storing, deflating or Zstandard.
        case unsupportedEntry(path: String)
    }

    /// How an entry's contents are stored in the archive.
    public enum Compression: Hashable, Sendable {
        /// The contents are stored as they are (ZIP's method 0), without any compression pass.
        case none
        /// The contents are deflated (ZIP's method 8), unless that does not make them smaller, in which case they are
        /// stored as they are.
        case deflate
        /// The contents are compressed with Zstandard (ZIP's method 93), unless that does not make them smaller, in which
        /// case they are stored as they are.
        ///
        /// - Important: Many extractors cannot read Zstandard entries, among them Info-ZIP's `unzip` and macOS's Archive
        ///     Utility; prefer ``deflate`` for archives that anyone may open.
        case zstd
    }

    /// The values from which on the archive writes ZIP64 fields; tests lower them to write ZIP64 without gigabytes.
    struct Limits {
        /// A size or offset at least this large is written as `0xFFFFFFFF` in its classic field and in full in a ZIP64
        /// field.
        var field = UInt64(UInt32.max)
        /// An entry count at least this large is written as `0xFFFF` in the end record and in full in a ZIP64 one.
        var entryCount = UInt64(UInt16.max)
    }

    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndRecordSignature: UInt32 = 0x0606_4B50
    private static let zip64EndRecordLocatorSignature: UInt32 = 0x0706_4B50
    /// The tag of the ZIP64 extended information extra field (APPNOTE §4.5.3).
    private static let zip64ExtraFieldTag: UInt16 = 0x0001
    /// The bytes read from a streamed file at a time.
    private static let streamChunkSize = 1 << 20

    private let url: URL
    private let handle: FileHandle
    private let limits: Limits
    /// The number of bytes written so far: the offset of the next local header.
    private var offset: UInt64 = 0
    private var centralDirectory = Data()
    private var entryCount: UInt64 = 0
    private var paths = Set<String>()
    /// Whether a write failed part of the way through, which leaves the file without a consistent structure.
    private var hasFailed = false
    private var isFinalized = false

    /// Creates the archive's file at `url`, replacing any file there.
    public init(writingTo url: URL) throws {
        try self.init(writingTo: url, limits: Limits())
    }

    /// Creates the archive's file at `url`, replacing any file there, writing ZIP64 fields from `limits` on.
    init(writingTo url: URL, limits: Limits) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        // https://github.com/swiftlang/swift/issues/68122
        let handle = try FileHandle(forWritingTo: url)
        self.url = url
        self.handle = handle
        self.limits = limits
    }

    /// Appends a file entry at `path`, relative to the archive's root, with `/` separating its components.
    ///
    /// - parameter compression: How the entry's contents are stored; ``Compression/none`` for contents that are
    ///     already compressed, which another compression pass would only spend time on.
    /// - throws: ``ZipError/invalidPath(_:)`` or ``ZipError/duplicatePath(_:)`` for a path the archive cannot hold, in
    ///     which case nothing is written; a failure to write leaves the archive unusable.
    public mutating func addEntry(at path: String, contents: Data, compression: Compression = .deflate) throws {
        let name = try validatedName(of: path)
        let (method, payload) = try Self.encode(contents, compression: compression)
        let header = Header(
            name: name,
            method: method,
            crc32: Self.crc32(contents),
            compressedSize: UInt64(payload.count),
            size: UInt64(contents.count),
            localHeaderOffset: offset,
            limit: limits.field
        )
        let localHeader = header.localFileHeader()
        try write(localHeader)
        try write(payload)
        offset += UInt64(localHeader.count) + UInt64(payload.count)
        centralDirectory.append(header.centralDirectoryHeader())
        entryCount += 1
        paths.insert(path)
    }

    /// Appends a file entry at `path` holding the contents of the file at `fileURL`, stored as they are.
    ///
    /// The file is read and written one chunk at a time, and its CRC-32 is computed on the way, so memory stays flat
    /// however large the file is. The entry is stored without compression: a file streamed in is usually in a format of
    /// its own, such as a PDF or an image, that another compression pass would only spend time on.
    ///
    /// - throws: ``ZipError/invalidPath(_:)`` or ``ZipError/duplicatePath(_:)`` for a path the archive cannot hold, and
    ///     any error reading the file before it is started, in which case nothing is written;
    ///     ``ZipError/sourceChanged(path:)`` if the file holds another number of bytes once read. A failure once the entry
    ///     is started leaves the archive unusable.
    public mutating func addEntry(at path: String, contentsOf fileURL: URL) throws {
        let name = try validatedName(of: path)
        let source = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? source.close()
        }
        let size = try source.seekToEnd()
        try source.seek(toOffset: 0)
        var header = Header(
            name: name,
            method: .stored,
            crc32: 0,
            compressedSize: size,
            size: size,
            localHeaderOffset: offset,
            limit: limits.field
        )
        // The CRC-32 is only known once the file is read, so the local header is written with none and patched after.
        let localHeader = header.localFileHeader()
        try write(localHeader)
        var crc = StreamingCRC32()
        var written: UInt64 = 0
        do {
            while let chunk = try source.read(upToCount: Self.streamChunkSize), !chunk.isEmpty {
                crc.update(chunk)
                try handle.write(contentsOf: chunk)
                written += UInt64(chunk.count)
            }
            guard written == size else {
                throw ZipError.sourceChanged(path: path)
            }
            header.crc32 = crc.value
            try handle.seek(toOffset: offset + Header.crc32OffsetInLocalHeader)
            var crcField = Data()
            crcField.appendLittleEndian(header.crc32)
            try handle.write(contentsOf: crcField)
            try handle.seekToEnd()
        } catch {
            hasFailed = true
            throw error
        }
        offset += UInt64(localHeader.count) + size
        centralDirectory.append(header.centralDirectoryHeader())
        entryCount += 1
        paths.insert(path)
    }

    /// Appends the central directory and closes the file, which then holds the complete archive.
    ///
    /// The end record states the entry count and the central directory's size and offset; where one is too large for its
    /// field, a ZIP64 end record and its locator precede it and state them in full.
    public consuming func finalize() throws {
        try ensureUsable()
        let centralDirectoryOffset = offset
        let centralDirectorySize = UInt64(centralDirectory.count)
        let needsZip64 = entryCount >= limits.entryCount
            || centralDirectoryOffset >= limits.field
            || centralDirectorySize >= limits.field
        var trailer = centralDirectory
        if needsZip64 {
            let zip64EndRecordOffset = centralDirectoryOffset + centralDirectorySize
            trailer.appendLittleEndian(ZipArchive.zip64EndRecordSignature)
            trailer.appendLittleEndian(UInt64(44)) // size of the record that follows this field
            trailer.appendLittleEndian(Header.versionMadeBy)
            trailer.appendLittleEndian(Header.zip64VersionNeeded)
            trailer.appendLittleEndian(UInt32(0)) // number of this disk
            trailer.appendLittleEndian(UInt32(0)) // disk on which the central directory starts
            trailer.appendLittleEndian(entryCount) // entries on this disk
            trailer.appendLittleEndian(entryCount) // entries in total
            trailer.appendLittleEndian(centralDirectorySize)
            trailer.appendLittleEndian(centralDirectoryOffset)
            trailer.appendLittleEndian(ZipArchive.zip64EndRecordLocatorSignature)
            trailer.appendLittleEndian(UInt32(0)) // disk on which the ZIP64 end record starts
            trailer.appendLittleEndian(zip64EndRecordOffset)
            trailer.appendLittleEndian(UInt32(1)) // total number of disks
        }
        let entryCountField = entryCount >= limits.entryCount ? UInt16.max : UInt16(entryCount)
        trailer.appendLittleEndian(ZipArchive.endOfCentralDirectorySignature)
        trailer.appendLittleEndian(UInt16(0)) // number of this disk
        trailer.appendLittleEndian(UInt16(0)) // disk on which the central directory starts
        trailer.appendLittleEndian(entryCountField) // entries on this disk
        trailer.appendLittleEndian(entryCountField) // entries in total
        trailer.appendLittleEndian(Header.field(centralDirectorySize, limit: limits.field))
        trailer.appendLittleEndian(Header.field(centralDirectoryOffset, limit: limits.field))
        trailer.appendLittleEndian(UInt16(0)) // comment length
        try write(trailer)
        try handle.close()
        isFinalized = true
    }

    /// `path` as an entry name, checked to be one the archive can add.
    private func validatedName(of path: String) throws -> Data {
        try ensureUsable()
        try Self.validatePath(path)
        guard !paths.contains(path) else {
            throw ZipError.duplicatePath(path)
        }
        let name = Data(path.utf8)
        guard name.count <= Int(UInt16.max) else {
            throw ZipError.tooLarge
        }
        return name
    }

    private func ensureUsable() throws {
        guard !hasFailed else {
            throw ZipError.writeFailed
        }
    }

    private mutating func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            hasFailed = true
            throw error
        }
    }

    deinit {
        if !isFinalized {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }
}


extension ZipArchive {
    /// Validates the path of an entry w/in the archive.
    private static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ZipError.invalidPath(path)
        }
    }

    /// The entry's method and the bytes stored for it: compressed as `compression` asks, if that makes them smaller, and
    /// stored as they are otherwise.
    private static func encode(_ contents: Data, compression: Compression) throws -> (Method, Data) {
        guard !contents.isEmpty else {
            return (.stored, contents)
        }
        switch compression {
        case .none:
            return (.stored, contents)
        case .deflate:
            let deflated = try rawDeflate(contents)
            return deflated.count < contents.count ? (.deflated, deflated) : (.stored, contents)
        case .zstd:
            let compressed: Data
            do {
                compressed = try Zstd.compress(contents)
            } catch {
                throw ZipError.compressionFailed
            }
            return compressed.count < contents.count ? (.zstd, compressed) : (.stored, contents)
        }
    }

    /// The raw DEFLATE stream ZIP stores, without the zlib format's header and trailer.
    private static func rawDeflate(_ contents: Data) throws -> Data {
        var stream = z_stream()
        // Negative window bits select raw DEFLATE; 8 is zlib's default memory level.
        guard deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw ZipError.compressionFailed
        }
        defer {
            deflateEnd(&stream)
        }
        // zlib counts its buffers in 32 bits, and the bound on the output can exceed the input's count.
        guard let inputCount = uInt(exactly: contents.count),
              let outputCount = uInt(exactly: deflateBound(&stream, uLong(inputCount))),
              let outputByteCount = Int(exactly: outputCount) else {
            throw ZipError.tooLarge
        }
        var output = Data(count: outputByteCount)
        let status = contents.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                stream.next_in = input.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self)) }
                stream.avail_in = inputCount
                stream.next_out = output.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = outputCount
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            throw ZipError.compressionFailed
        }
        output.count = Int(stream.total_out)
        return output
    }

    /// The `size` bytes a raw DEFLATE stream decompresses to; anything but exactly that many is malformed.
    private static func rawInflate(_ payload: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZipError.malformedArchive
        }
        defer {
            inflateEnd(&stream)
        }
        guard let inputCount = uInt(exactly: payload.count), let outputCount = uInt(exactly: size + 1) else {
            throw ZipError.malformedArchive
        }
        // One byte more than expected, so that a stream decompressing to more than `size` bytes cannot pass for one
        // that ends exactly there, and so that zlib always gets an output buffer, also for an empty entry.
        var output = Data(count: Int(outputCount))
        let status = payload.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                stream.next_in = input.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self)) }
                stream.avail_in = inputCount
                stream.next_out = output.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = outputCount
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == size else {
            throw ZipError.malformedArchive
        }
        output.count = size
        return output
    }
}


// MARK: Reading

extension ZipArchive {
    /// An entry of an archive, as the archive's central directory describes it, without its contents.
    public struct EntryInfo: Hashable, Sendable {
        /// The entry's path within the archive, relative to its root, with `/` separating its components.
        public let path: String
        /// The size of the entry's contents, in bytes.
        public let size: Int
        /// The number of bytes the archive stores for the entry's contents.
        public let compressedSize: Int
        /// How the entry's contents are stored.
        public let compression: Compression
        /// The CRC-32 of the entry's contents.
        public let crc32: UInt32
        /// The offset of the entry's local header within the archive.
        fileprivate let localHeaderOffset: Int
    }

    /// Where an archive's central directory is, and how many entries it lists.
    private struct CentralDirectoryLocation {
        let offset: Int
        let size: Int
        let entryCount: Int
    }

    /// Reads an archive one entry at a time.
    ///
    /// Creating a reader reads only the archive's central directory, which lists its ``entries``; ``contents(of:)`` then
    /// reads, decompresses and checks the contents of one entry, and of no other. Reading from a file seeks to the parts
    /// it needs, so the archive is never held in memory as a whole.
    ///
    /// An archive states each entry's size itself, so the reader refuses to decompress any entry larger than its
    /// `maximumEntrySize` before it allocates any memory for the entry.
    public struct Reader {
        /// The largest entry a reader decompresses unless told otherwise: 1 GiB.
        public static let defaultMaximumEntrySize = 1 << 30

        /// The archive's entries, in central-directory order.
        public let entries: [EntryInfo]
        /// The size of the largest entry this reader decompresses, in bytes.
        public let maximumEntrySize: Int
        private let source: Source

        /// Reads the central directory of the archive at `url`.
        public init(contentsOf url: URL, maximumEntrySize: Int = Reader.defaultMaximumEntrySize) throws {
            try self.init(source: Source(fileAt: url), maximumEntrySize: maximumEntrySize)
        }

        /// Reads the central directory of the archive `data` holds.
        public init(_ data: Data, maximumEntrySize: Int = Reader.defaultMaximumEntrySize) throws {
            try self.init(source: Source(data), maximumEntrySize: maximumEntrySize)
        }

        private init(source: Source, maximumEntrySize: Int) throws {
            let directory = try Self.centralDirectoryLocation(in: source)
            var centralDirectory = ByteReader(
                try source.read(at: directory.offset, count: directory.size),
                offset: 0
            )
            let entryCount = directory.entryCount
            var entries: [EntryInfo] = []
            entries.reserveCapacity(Swift.min(entryCount, 1 << 16))
            var paths = Set<String>()
            for _ in 0..<entryCount {
                let entry = try Self.readEntryInfo(at: &centralDirectory)
                // Readers disagree on which of two entries under one path wins, so an archive may not have any.
                guard paths.insert(entry.path).inserted else {
                    throw ZipError.duplicatePath(entry.path)
                }
                entries.append(entry)
            }
            self.entries = entries
            self.maximumEntrySize = maximumEntrySize
            self.source = source
        }

        /// Where the central directory is and how many entries it lists, as the end record states it, or the ZIP64 end
        /// record where the end record defers to one.
        private static func centralDirectoryLocation(in source: Source) throws -> CentralDirectoryLocation {
            let endRecordOffset = try Self.endOfCentralDirectoryOffset(in: source)
            var endRecord = ByteReader(try source.read(at: endRecordOffset + 4, count: 18), offset: 0)
            let disk = try endRecord.read(UInt16.self)
            let centralDirectoryDisk = try endRecord.read(UInt16.self)
            let entriesOnDisk = try endRecord.read(UInt16.self)
            let entryCount = try endRecord.read(UInt16.self)
            let centralDirectorySize = try endRecord.read(UInt32.self)
            let centralDirectoryOffset = try endRecord.read(UInt32.self)
            guard disk == 0, centralDirectoryDisk == 0, entriesOnDisk == entryCount else {
                throw ZipError.malformedArchive
            }
            let defersToZip64 = entryCount == UInt16.max
                || centralDirectorySize == UInt32.max
                || centralDirectoryOffset == UInt32.max
            let location: CentralDirectoryLocation
            let directoryEnd: Int
            if defersToZip64 {
                (location, directoryEnd) = try zip64CentralDirectoryLocation(in: source, endRecordOffset: endRecordOffset)
            } else {
                location = CentralDirectoryLocation(
                    offset: try Int.exactly(centralDirectoryOffset),
                    size: try Int.exactly(centralDirectorySize),
                    entryCount: Int(entryCount)
                )
                directoryEnd = endRecordOffset
            }
            guard location.offset <= directoryEnd, location.size <= directoryEnd - location.offset else {
                throw ZipError.malformedArchive
            }
            return location
        }

        /// The central directory's location as the ZIP64 end record states it, which the locator just before the end
        /// record at `endRecordOffset` points at, and the offset that record starts at, where the central directory ends.
        private static func zip64CentralDirectoryLocation(
            in source: Source,
            endRecordOffset: Int
        ) throws -> (location: CentralDirectoryLocation, directoryEnd: Int) {
            let locatorSize = 20
            guard endRecordOffset >= locatorSize else {
                throw ZipError.malformedArchive
            }
            var locator = ByteReader(try source.read(at: endRecordOffset - locatorSize, count: locatorSize), offset: 0)
            guard try locator.read(UInt32.self) == ZipArchive.zip64EndRecordLocatorSignature,
                  try locator.read(UInt32.self) == 0 else { // disk on which the ZIP64 end record starts
                throw ZipError.malformedArchive
            }
            let recordOffset = try locator.readSize64()
            guard try locator.read(UInt32.self) == 1, // total number of disks
                  recordOffset <= endRecordOffset - locatorSize - 56 else {
                throw ZipError.malformedArchive
            }
            var record = ByteReader(try source.read(at: recordOffset, count: 56), offset: 0)
            guard try record.read(UInt32.self) == ZipArchive.zip64EndRecordSignature else {
                throw ZipError.malformedArchive
            }
            _ = try record.read(UInt64.self) // size of the record
            _ = try record.read(UInt16.self) // version made by
            _ = try record.read(UInt16.self) // version needed to extract
            let disk = try record.read(UInt32.self)
            let centralDirectoryDisk = try record.read(UInt32.self)
            let entriesOnDisk = try record.read(UInt64.self)
            let entryCount = try record.read(UInt64.self)
            let size = try record.readSize64()
            let offset = try record.readSize64()
            guard disk == 0, centralDirectoryDisk == 0, entriesOnDisk == entryCount else {
                throw ZipError.malformedArchive
            }
            return (CentralDirectoryLocation(offset: offset, size: size, entryCount: try Int.exactly(entryCount)), recordOffset)
        }

        /// The values of a ZIP64 extended information extra field among `extraFields`, in the order they appear, or
        /// none where there is no such field.
        private static func zip64Values(in extraFields: Data) throws -> [UInt64] {
            var extra = ByteReader(extraFields, offset: 0)
            while !extra.isAtEnd {
                let tag = try extra.read(UInt16.self)
                let length = Int(try extra.read(UInt16.self))
                let data = try extra.read(byteCount: length)
                guard tag == ZipArchive.zip64ExtraFieldTag else {
                    continue
                }
                guard length.isMultiple(of: 8) else {
                    throw ZipError.malformedArchive
                }
                var values = ByteReader(data, offset: 0)
                return try (0..<(length / 8)).map { _ in try values.read(UInt64.self) }
            }
            return []
        }

        /// The classic 32-bit `fields` resolved: each that is `0xFFFFFFFF` takes the next of `zip64Values`, in order.
        private static func resolve(_ fields: [UInt32], with zip64Values: [UInt64]) throws -> [Int] {
            var remaining = zip64Values[...]
            return try fields.map { field in
                guard field == UInt32.max else {
                    return try Int.exactly(field)
                }
                guard let value = remaining.popFirst() else {
                    throw ZipError.malformedArchive
                }
                return try Int.exactly(value)
            }
        }

        /// Reads the entry whose central-directory header `centralDirectory` is positioned at, and advances it past it.
        private static func readEntryInfo(at centralDirectory: inout ByteReader) throws -> EntryInfo {
            guard try centralDirectory.read(UInt32.self) == ZipArchive.centralDirectoryHeaderSignature else {
                throw ZipError.malformedArchive
            }
            _ = try centralDirectory.read(UInt16.self) // version made by
            _ = try centralDirectory.read(UInt16.self) // version needed to extract
            let flags = GeneralPurposeFlags(rawValue: try centralDirectory.read(UInt16.self))
            let method = try centralDirectory.read(UInt16.self)
            _ = try centralDirectory.read(UInt16.self) // modification time
            _ = try centralDirectory.read(UInt16.self) // modification date
            let crc32 = try centralDirectory.read(UInt32.self)
            let compressedSizeField = try centralDirectory.read(UInt32.self)
            let sizeField = try centralDirectory.read(UInt32.self)
            let nameLength = try centralDirectory.read(UInt16.self)
            let extraLength = try centralDirectory.read(UInt16.self)
            let commentLength = try centralDirectory.read(UInt16.self)
            _ = try centralDirectory.read(UInt16.self) // disk number start
            _ = try centralDirectory.read(UInt16.self) // internal attributes
            _ = try centralDirectory.read(UInt32.self) // external attributes
            let localHeaderOffsetField = try centralDirectory.read(UInt32.self)
            let path = String(decoding: try centralDirectory.read(byteCount: Int(nameLength)), as: UTF8.self)
            let extraFields = try centralDirectory.read(byteCount: Int(extraLength))
            _ = try centralDirectory.read(byteCount: Int(commentLength))
            // APPNOTE §4.5.3 orders the ZIP64 values as the size, the compressed size, then the offset.
            let resolved = try resolve(
                [sizeField, compressedSizeField, localHeaderOffsetField],
                with: try zip64Values(in: extraFields)
            )
            let (size, compressedSize, localHeaderOffset) = (resolved[0], resolved[1], resolved[2])
            guard !flags.contains(.encrypted), let method = Method(rawValue: method) else {
                throw ZipError.unsupportedEntry(path: path)
            }
            // A stored entry's contents are its stored bytes.
            guard method != .stored || compressedSize == size else {
                throw ZipError.malformedArchive
            }
            return EntryInfo(
                path: path,
                size: size,
                compressedSize: compressedSize,
                compression: method.compression,
                crc32: crc32,
                localHeaderOffset: localHeaderOffset
            )
        }

        /// The offset of the end-of-central-directory record, which ends the archive, followed only by its comment.
        private static func endOfCentralDirectoryOffset(in source: Source) throws -> Int {
            let recordSize = 22
            guard source.size >= recordSize else {
                throw ZipError.malformedArchive
            }
            // The record is followed by a comment of at most 65,535 bytes, so it starts within the archive's tail.
            let tailOffset = max(0, source.size - recordSize - Int(UInt16.max))
            let tail = try source.read(at: tailOffset, count: source.size - tailOffset)
            for offset in stride(from: tail.count - recordSize, through: 0, by: -1) {
                var reader = ByteReader(tail, offset: offset)
                guard try reader.read(UInt32.self) == ZipArchive.endOfCentralDirectorySignature else {
                    continue
                }
                _ = try reader.read(byteCount: 16) // disks, entry counts, central directory size and offset
                // The record is followed by exactly its comment; a signature within a comment is followed by more.
                if offset + recordSize + Int(try reader.read(UInt16.self)) == tail.count {
                    return tailOffset + offset
                }
            }
            throw ZipError.malformedArchive
        }

        /// The contents of `entry`, one of this archive's ``entries``, checked against its size and CRC-32.
        ///
        /// - throws: ``ZipError/sizeLimitExceeded(path:)`` for an entry larger than ``maximumEntrySize``.
        public func contents(of entry: EntryInfo) throws -> Data {
            guard entry.size <= maximumEntrySize else {
                throw ZipError.sizeLimitExceeded(path: entry.path)
            }
            let dataOffset = try dataOffset(of: entry)
            let payload = try source.read(at: dataOffset, count: entry.compressedSize)
            let contents: Data
            switch entry.compression {
            case .none:
                contents = payload
            case .deflate:
                contents = try ZipArchive.rawInflate(payload, size: entry.size)
            case .zstd:
                do {
                    // Bounded by the declared size, so that a frame cannot claim an arbitrarily large output buffer.
                    contents = try Zstd.decompress(payload, maximumDecompressedSize: entry.size)
                } catch {
                    throw ZipError.malformedArchive
                }
            }
            guard contents.count == entry.size, ZipArchive.crc32(contents) == entry.crc32 else {
                throw ZipError.malformedArchive
            }
            return contents
        }

        /// The offset of `entry`'s stored bytes, after its local header, which must describe the entry as the central
        /// directory does.
        private func dataOffset(of entry: EntryInfo) throws -> Int {
            var localHeader = ByteReader(try source.read(at: entry.localHeaderOffset, count: 30), offset: 0)
            guard try localHeader.read(UInt32.self) == ZipArchive.localFileHeaderSignature else {
                throw ZipError.malformedArchive
            }
            _ = try localHeader.read(UInt16.self) // version needed to extract
            let flags = GeneralPurposeFlags(rawValue: try localHeader.read(UInt16.self))
            let method = try localHeader.read(UInt16.self)
            _ = try localHeader.read(UInt16.self) // modification time
            _ = try localHeader.read(UInt16.self) // modification date
            let crc32 = try localHeader.read(UInt32.self)
            let compressedSizeField = try localHeader.read(UInt32.self)
            let sizeField = try localHeader.read(UInt32.self)
            let nameLength = Int(try localHeader.read(UInt16.self))
            let extraLength = Int(try localHeader.read(UInt16.self))
            // The local header precedes the stored bytes `entry.localHeaderOffset` points at, which the read above checked.
            let nameOffset = entry.localHeaderOffset + 30
            let name = try source.read(at: nameOffset, count: nameLength)
            // A local header's ZIP64 field holds the size and then the compressed size (APPNOTE §4.5.3).
            let resolved = try Self.resolve(
                [sizeField, compressedSizeField],
                with: try Self.zip64Values(in: try source.read(at: nameOffset + nameLength, count: extraLength))
            )
            let (size, compressedSize) = (resolved[0], resolved[1])
            // The local header must describe the entry as the central directory does; with a data descriptor, it leaves
            // the CRC-32 and the sizes to the descriptor that follows the stored bytes.
            guard String(decoding: name, as: UTF8.self) == entry.path,
                  Method(rawValue: method)?.compression == entry.compression,
                  !flags.contains(.encrypted),
                  flags.contains(.dataDescriptor)
                    || (crc32 == entry.crc32 && compressedSize == entry.compressedSize && size == entry.size) else {
                throw ZipError.malformedArchive
            }
            let (dataOffset, overflow) = nameOffset.addingReportingOverflow(nameLength + extraLength)
            guard !overflow else {
                throw ZipError.malformedArchive
            }
            return dataOffset
        }
    }

    /// Random access to an archive's bytes, held in memory or read from a file.
    private struct Source {
        /// The archive's size, in bytes.
        let size: Int
        private let readBytes: (_ offset: Int, _ count: Int) throws -> Data

        init(_ data: Data) {
            size = data.count
            readBytes = { offset, count in
                let start = data.startIndex + offset
                return data.subdata(in: start..<(start + count))
            }
        }

        init(fileAt url: URL) throws {
            let handle = try FileHandle(forReadingFrom: url)
            guard let size = Int(exactly: try handle.seekToEnd()) else {
                throw ZipError.tooLarge
            }
            self.size = size
            readBytes = { offset, count in
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: count) ?? Data()
            }
        }

        /// The `count` bytes at `offset`, which must lie within the archive.
        func read(at offset: Int, count: Int) throws -> Data {
            guard offset >= 0, count >= 0, count <= size - offset else {
                throw ZipError.malformedArchive
            }
            let bytes = try readBytes(offset, count)
            guard bytes.count == count else {
                throw ZipError.malformedArchive
            }
            return bytes
        }
    }

    /// Reads all entries of the archive `data` holds, with their contents, in central-directory order.
    ///
    /// - parameter maximumTotalSize: The largest number of bytes all entries' contents may add up to; an archive whose
    ///     entries exceed it is refused before any entry is read.
    public static func entries(in data: Data, maximumTotalSize: Int = Reader.defaultMaximumEntrySize) throws -> [Entry] {
        let reader = try Reader(data, maximumEntrySize: maximumTotalSize)
        var totalSize = 0
        for entry in reader.entries {
            // Compared before adding, so that the sum cannot overflow.
            guard entry.size <= maximumTotalSize - totalSize else {
                throw ZipError.sizeLimitExceeded(path: entry.path)
            }
            totalSize += entry.size
        }
        return try reader.entries.map { Entry(path: $0.path, contents: try reader.contents(of: $0)) }
    }
}


// MARK: Format

extension ZipArchive {
    private enum Method: UInt16 {
        case stored = 0
        case deflated = 8
        case zstd = 93

        /// The compression this method applies.
        var compression: Compression {
            switch self {
            case .stored: .none
            case .deflated: .deflate
            case .zstd: .zstd
            }
        }

        /// The ZIP specification version an extractor needs: 1.0 for stored entries, 2.0 for deflated ones, and 6.3 for
        /// Zstandard ones.
        var versionNeeded: UInt16 {
            switch self {
            case .stored: 10
            case .deflated: 20
            case .zstd: 63
            }
        }
    }

    /// The general purpose bit flags of an entry's headers (APPNOTE §4.4.4).
    private struct GeneralPurposeFlags: OptionSet {
        /// Bit 0: the entry is encrypted.
        static let encrypted = Self(rawValue: 1 << 0)
        /// Bit 3: the entry's CRC-32 and sizes follow its stored bytes, in a data descriptor, rather than its local header.
        static let dataDescriptor = Self(rawValue: 1 << 3)
        /// Bit 11, the language encoding flag: the entry's path is UTF-8.
        static let utf8Path = Self(rawValue: 1 << 11)

        let rawValue: UInt16
    }

    /// The file type a UNIX file mode states in its `S_IFMT` bits.
    private enum UnixFileType: UInt16 {
        /// `S_IFREG`: a regular file.
        case regularFile = 0o100000
    }

    /// The permission bits of a UNIX file mode.
    private struct UnixFilePermissions: OptionSet {
        /// `S_IRUSR`: the owner may read the file.
        static let ownerRead = Self(rawValue: 0o400)
        /// `S_IWUSR`: the owner may write the file.
        static let ownerWrite = Self(rawValue: 0o200)
        /// `S_IRGRP`: the group may read the file.
        static let groupRead = Self(rawValue: 0o040)
        /// `S_IROTH`: everyone else may read the file.
        static let othersRead = Self(rawValue: 0o004)

        let rawValue: UInt16
    }

    /// The fields an entry's local header and its central-directory header share.
    private struct Header {
        /// 1980-01-01 00:00:00, the earliest MS-DOS timestamp, for every entry.
        private static let modificationTime: UInt16 = 0
        private static let modificationDate: UInt16 = (1 << 5) | 1
        private static let flags: GeneralPurposeFlags = [.utf8Path]
        /// Made by a UNIX system, under version 6.3 of the specification, which the newest method written (Zstandard)
        /// needs. Extractors convert the paths of entries made on MS-DOS from its code page, which would garble any
        /// non-ASCII UTF-8 path.
        static let versionMadeBy: UInt16 = 3 << 8 | 63
        /// The version of the specification an extractor needs for ZIP64 fields: 4.5.
        static let zip64VersionNeeded: UInt16 = 45
        /// Where the CRC-32 sits in a local header: after the signature, version, flags, method, time and date.
        static let crc32OffsetInLocalHeader: UInt64 = 14
        /// Every entry is a regular file, readable by everyone and writable by its owner (`-rw-r--r--`).
        private static let fileType = UnixFileType.regularFile
        private static let permissions: UnixFilePermissions = [.ownerRead, .ownerWrite, .groupRead, .othersRead]

        let name: Data
        let method: Method
        var crc32: UInt32
        let compressedSize: UInt64
        let size: UInt64
        let localHeaderOffset: UInt64
        /// The value from which on a size or offset is written in a ZIP64 field.
        let limit: UInt64

        /// Whether the sizes need ZIP64 fields; if so, both are written there, as a local header must.
        private var sizesNeedZip64: Bool {
            size >= limit || compressedSize >= limit
        }

        /// Whether the local header's offset needs a ZIP64 field, which only the central directory states.
        private var offsetNeedsZip64: Bool {
            localHeaderOffset >= limit
        }

        /// `value` as its classic 32-bit field states it: in full below `limit`, and as `0xFFFFFFFF`, which defers to a
        /// ZIP64 field, from it on.
        static func field(_ value: UInt64, limit: UInt64) -> UInt32 {
            value >= limit ? UInt32.max : UInt32(value)
        }

        /// The ZIP64 extended information extra field holding `values`, or nothing when there are none.
        private static func zip64ExtraField(_ values: [UInt64]) -> Data {
            guard !values.isEmpty else {
                return Data()
            }
            var field = Data()
            field.appendLittleEndian(ZipArchive.zip64ExtraFieldTag)
            field.appendLittleEndian(UInt16(values.count * 8))
            for value in values {
                field.appendLittleEndian(value)
            }
            return field
        }

        private func versionNeeded(zip64: Bool) -> UInt16 {
            zip64 ? Swift.max(method.versionNeeded, Self.zip64VersionNeeded) : method.versionNeeded
        }

        func localFileHeader() -> Data {
            let extra = Self.zip64ExtraField(sizesNeedZip64 ? [size, compressedSize] : [])
            var header = Data()
            header.appendLittleEndian(ZipArchive.localFileHeaderSignature)
            header.appendLittleEndian(versionNeeded(zip64: sizesNeedZip64))
            appendCommonFields(to: &header)
            header.appendLittleEndian(UInt16(extra.count)) // extra field length
            header.append(name)
            header.append(extra)
            return header
        }

        func centralDirectoryHeader() -> Data {
            // In the order APPNOTE §4.5.3 sets, each only where its classic field defers to it.
            let extra = Self.zip64ExtraField(
                (sizesNeedZip64 ? [size, compressedSize] : []) + (offsetNeedsZip64 ? [localHeaderOffset] : [])
            )
            var header = Data()
            header.appendLittleEndian(ZipArchive.centralDirectoryHeaderSignature)
            header.appendLittleEndian(Self.versionMadeBy)
            header.appendLittleEndian(versionNeeded(zip64: sizesNeedZip64 || offsetNeedsZip64))
            appendCommonFields(to: &header)
            header.appendLittleEndian(UInt16(extra.count)) // extra field length
            header.appendLittleEndian(UInt16(0)) // comment length
            header.appendLittleEndian(UInt16(0)) // disk number start
            header.appendLittleEndian(UInt16(0)) // internal attributes
            // The external attributes: the UNIX file mode (file type and permissions) in their upper half, MS-DOS
            // attributes (none) in their lower half.
            header.appendLittleEndian(UInt32(Self.fileType.rawValue | Self.permissions.rawValue) << 16)
            header.appendLittleEndian(offsetNeedsZip64 ? UInt32.max : UInt32(localHeaderOffset))
            header.append(name)
            header.append(extra)
            return header
        }

        /// The fields from the flags through the name length, which both headers state alike.
        private func appendCommonFields(to header: inout Data) {
            header.appendLittleEndian(Self.flags.rawValue)
            header.appendLittleEndian(method.rawValue)
            header.appendLittleEndian(Self.modificationTime)
            header.appendLittleEndian(Self.modificationDate)
            header.appendLittleEndian(crc32)
            header.appendLittleEndian(sizesNeedZip64 ? UInt32.max : UInt32(compressedSize))
            header.appendLittleEndian(sizesNeedZip64 ? UInt32.max : UInt32(size))
            // `ZipArchive` checks every name's length before it builds a header.
            header.appendLittleEndian(UInt16(name.count))
        }
    }
}


extension ZipArchive {
    /// Reads little-endian fields from an archive, failing on any read past its end.
    private struct ByteReader {
        private let data: Data
        private var offset: Int

        /// Whether every byte has been read.
        var isAtEnd: Bool {
            offset >= data.count
        }

        init(_ data: Data, offset: Int) {
            self.data = data
            self.offset = offset
        }

        mutating func read(byteCount: Int) throws -> Data {
            guard byteCount >= 0, offset >= 0, byteCount <= data.count - offset else {
                throw ZipArchive.ZipError.malformedArchive
            }
            let start = data.startIndex + offset
            offset += byteCount
            return Data(data[start..<(start + byteCount)])
        }

        /// A 64-bit size or offset, which is malformed where it does not fit an `Int` (whose width is 32 bits on watchOS).
        mutating func readSize64() throws -> Int {
            try Int.exactly(try read(UInt64.self))
        }

        mutating func read<Value: FixedWidthInteger>(_: Value.Type) throws -> Value {
            try read(byteCount: MemoryLayout<Value>.size).reversed().reduce(Value.zero) { $0 << 8 | Value($1) }
        }
    }
}


extension Int {
    /// `value` as an `Int`; a size or offset that does not fit one (whose width is 32 bits on watchOS) is malformed.
    fileprivate static func exactly(_ value: some BinaryInteger) throws -> Int {
        guard let result = Int(exactly: value) else {
            throw ZipArchive.ZipError.malformedArchive
        }
        return result
    }
}


extension Data {
    fileprivate mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}


extension ZipArchive {
    /// A CRC-32 (ISO-HDLC, as ZIP stores it) over bytes that arrive one chunk at a time.
    fileprivate struct StreamingCRC32 {
        /// zlib's running value, which starts at 0.
        private var crc: uLong = 0

        /// The CRC-32 of every byte so far.
        var value: UInt32 {
            UInt32(truncatingIfNeeded: crc)
        }

        mutating func update(_ bytes: Data) {
            bytes.withUnsafeBytes { buffer in
                var start = 0
                // zlib counts its input in 32 bits.
                while start < buffer.count {
                    let count = Swift.min(buffer.count - start, Int(Int32.max))
                    let chunk = UnsafeRawBufferPointer(rebasing: buffer[start..<(start + count)])
                    crc = zlibCRC32(crc, chunk.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(count))
                    start += count
                }
            }
        }
    }


    /// The CRC-32 of each byte value, for the reflected polynomial `0xEDB88320`.
    private static let crc32Table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in
            crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
    }


    /// The CRC-32 (ISO-HDLC) checksum ZIP stores for each entry.
    static func crc32(_ bytes: Data) -> UInt32 {
        crc32Table.withUnsafeBufferPointer { table in
            bytes.withUnsafeBytes { bytes in
                ~bytes.reduce(~UInt32(0)) { crc, byte in
                    table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
    }
}


/// zlib's CRC-32 update, under a name of its own: within ``ZipArchive``, its `crc32(_:)` shadows zlib's.
private func zlibCRC32(_ crc: uLong, _ buffer: UnsafePointer<Bytef>?, _ count: uInt) -> uLong {
    crc32(crc, buffer, count)
}
