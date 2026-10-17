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
/// with Zstandard, without
/// ZIP64, encryption, data descriptors or extra fields. Writing is deterministic — entries are emitted in the order they
/// are added, all under the same fixed timestamp — so the same entries always produce the same bytes. Each entry is stored
/// as is or compressed, as the ``Compression`` it is added with says.
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
        /// The archive would need ZIP64: more than 65,535 entries, or an entry, offset or path too large for its field.
        case tooLarge
        /// Compressing an entry's contents failed.
        case compressionFailed
        /// An earlier write to the archive's file failed, leaving it without a consistent structure.
        case writeFailed
        /// The archive could not be parsed, or an entry's contents do not match its stored size or CRC-32.
        case malformedArchive
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

    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    private let url: URL
    private let handle: FileHandle
    /// The number of bytes written so far: the offset of the next local header.
    private var offset = 0
    private var centralDirectory = Data()
    private var entryCount = 0
    private var paths = Set<String>()
    /// Whether a write failed part of the way through, which leaves the file without a consistent structure.
    private var hasFailed = false
    private var isFinalized = false

    /// Creates the archive's file at `url`, replacing any file there.
    public init(writingTo url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        // https://github.com/swiftlang/swift/issues/68122
        let handle = try FileHandle(forWritingTo: url)
        self.url = url
        self.handle = handle
    }

    /// Appends a file entry at `path`, relative to the archive's root, with `/` separating its components.
    ///
    /// - parameter compression: How the entry's contents are stored; ``Compression/none`` for contents that are
    ///     already compressed, which another compression pass would only spend time on.
    /// - throws: ``ZipError/invalidPath(_:)`` or ``ZipError/duplicatePath(_:)`` for a path the archive cannot hold, in
    ///     which case nothing is written; a failure to write leaves the archive unusable.
    public mutating func addEntry(at path: String, contents: Data, compression: Compression = .deflate) throws {
        try ensureUsable()
        try Self.validatePath(path)
        guard !paths.contains(path) else {
            throw ZipError.duplicatePath(path)
        }
        guard entryCount < Int(UInt16.max) else {
            throw ZipError.tooLarge
        }
        let (method, payload) = try Self.encode(contents, compression: compression)
        guard let header = Header(
            name: Data(path.utf8),
            method: method,
            crc32: Self.crc32(contents),
            compressedSize: payload.count,
            size: contents.count,
            localHeaderOffset: offset
        ) else {
            throw ZipError.tooLarge
        }
        let localHeader = header.localFileHeader()
        try write(localHeader)
        try write(payload)
        offset += localHeader.count + payload.count
        centralDirectory.append(header.centralDirectoryHeader())
        entryCount += 1
        paths.insert(path)
    }

    /// Appends the central directory and closes the file, which then holds the complete archive.
    public consuming func finalize() throws {
        try ensureUsable()
        guard let centralDirectoryOffset = UInt32(exactly: offset),
              let centralDirectorySize = UInt32(exactly: centralDirectory.count) else {
            throw ZipError.tooLarge
        }
        var trailer = centralDirectory
        trailer.appendLittleEndian(ZipArchive.endOfCentralDirectorySignature)
        trailer.appendLittleEndian(UInt16(0)) // number of this disk
        trailer.appendLittleEndian(UInt16(0)) // disk on which the central directory starts
        trailer.appendLittleEndian(UInt16(entryCount)) // entries on this disk
        trailer.appendLittleEndian(UInt16(entryCount)) // entries in total
        trailer.appendLittleEndian(centralDirectorySize)
        trailer.appendLittleEndian(centralDirectoryOffset)
        trailer.appendLittleEndian(UInt16(0)) // comment length
        try write(trailer)
        try handle.close()
        isFinalized = true
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
        guard let inputCount = uInt(exactly: contents.count) else {
            throw ZipError.tooLarge
        }
        var output = Data(count: Int(deflateBound(&stream, uLong(inputCount))))
        let status = contents.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                stream.next_in = input.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self)) }
                stream.avail_in = inputCount
                stream.next_out = output.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(output.count)
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

    /// Reads an archive one entry at a time.
    ///
    /// Creating a reader reads only the archive's central directory, which lists its ``entries``; ``contents(of:)`` then
    /// reads, decompresses and checks the contents of one entry, and of no other. Reading from a file seeks to the parts
    /// it needs, so the archive is never held in memory as a whole.
    public struct Reader {
        /// The archive's entries, in central-directory order.
        public let entries: [EntryInfo]
        private let source: Source

        /// Reads the central directory of the archive at `url`.
        public init(contentsOf url: URL) throws {
            try self.init(source: Source(fileAt: url))
        }

        /// Reads the central directory of the archive `data` holds.
        public init(_ data: Data) throws {
            try self.init(source: Source(data))
        }

        private init(source: Source) throws {
            let endRecordOffset = try Self.endOfCentralDirectoryOffset(in: source)
            var endRecord = ByteReader(try source.read(at: endRecordOffset + 4, count: 18), offset: 0)
            let disk = try endRecord.read(UInt16.self)
            let centralDirectoryDisk = try endRecord.read(UInt16.self)
            let entriesOnDisk = try endRecord.read(UInt16.self)
            let entryCount = try endRecord.read(UInt16.self)
            let centralDirectorySize = Int(try endRecord.read(UInt32.self))
            let centralDirectoryOffset = Int(try endRecord.read(UInt32.self))
            guard disk == 0,
                  centralDirectoryDisk == 0,
                  entriesOnDisk == entryCount,
                  centralDirectoryOffset + centralDirectorySize <= endRecordOffset else {
                throw ZipError.malformedArchive
            }
            var centralDirectory = ByteReader(
                try source.read(at: centralDirectoryOffset, count: centralDirectorySize),
                offset: 0
            )
            var entries: [EntryInfo] = []
            entries.reserveCapacity(Int(entryCount))
            for _ in 0..<entryCount {
                entries.append(try Self.readEntryInfo(at: &centralDirectory))
            }
            self.entries = entries
            self.source = source
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
            let compressedSize = try centralDirectory.read(UInt32.self)
            let size = try centralDirectory.read(UInt32.self)
            let nameLength = try centralDirectory.read(UInt16.self)
            let extraLength = try centralDirectory.read(UInt16.self)
            let commentLength = try centralDirectory.read(UInt16.self)
            _ = try centralDirectory.read(UInt16.self) // disk number start
            _ = try centralDirectory.read(UInt16.self) // internal attributes
            _ = try centralDirectory.read(UInt32.self) // external attributes
            let localHeaderOffset = try centralDirectory.read(UInt32.self)
            let path = String(decoding: try centralDirectory.read(byteCount: Int(nameLength)), as: UTF8.self)
            _ = try centralDirectory.read(byteCount: Int(extraLength) + Int(commentLength))
            guard !flags.contains(.encrypted), let method = Method(rawValue: method) else {
                throw ZipError.unsupportedEntry(path: path)
            }
            return EntryInfo(
                path: path,
                size: Int(size),
                compressedSize: Int(compressedSize),
                compression: method.compression,
                crc32: crc32,
                localHeaderOffset: Int(localHeaderOffset)
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
                if try reader.read(UInt32.self) == ZipArchive.endOfCentralDirectorySignature {
                    return tailOffset + offset
                }
            }
            throw ZipError.malformedArchive
        }

        /// The contents of `entry`, one of this archive's ``entries``, checked against its size and CRC-32.
        public func contents(of entry: EntryInfo) throws -> Data {
            var localHeader = ByteReader(try source.read(at: entry.localHeaderOffset, count: 30), offset: 0)
            guard try localHeader.read(UInt32.self) == ZipArchive.localFileHeaderSignature else {
                throw ZipError.malformedArchive
            }
            _ = try localHeader.read(byteCount: 22) // version needed, flags, method, time, date, CRC-32, sizes
            let nameLength = Int(try localHeader.read(UInt16.self))
            let extraLength = Int(try localHeader.read(UInt16.self))
            let payload = try source.read(at: entry.localHeaderOffset + 30 + nameLength + extraLength, count: entry.compressedSize)
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
            size = Int(try handle.seekToEnd())
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
    public static func entries(in data: Data) throws -> [Entry] {
        let reader = try Reader(data)
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
        private static let versionMadeBy: UInt16 = 3 << 8 | 63
        /// Every entry is a regular file, readable by everyone and writable by its owner (`-rw-r--r--`).
        private static let fileType = UnixFileType.regularFile
        private static let permissions: UnixFilePermissions = [.ownerRead, .ownerWrite, .groupRead, .othersRead]

        let name: Data
        let nameLength: UInt16
        let method: Method
        let crc32: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32

        /// `nil` if a value does not fit its field.
        init?(name: Data, method: Method, crc32: UInt32, compressedSize: Int, size: Int, localHeaderOffset: Int) {
            guard let nameLength = UInt16(exactly: name.count),
                  let compressedSize = UInt32(exactly: compressedSize),
                  let size = UInt32(exactly: size),
                  let localHeaderOffset = UInt32(exactly: localHeaderOffset) else {
                return nil
            }
            self.name = name
            self.nameLength = nameLength
            self.method = method
            self.crc32 = crc32
            self.compressedSize = compressedSize
            self.size = size
            self.localHeaderOffset = localHeaderOffset
        }

        func localFileHeader() -> Data {
            var header = Data()
            header.appendLittleEndian(ZipArchive.localFileHeaderSignature)
            header.appendLittleEndian(method.versionNeeded)
            appendCommonFields(to: &header)
            header.appendLittleEndian(UInt16(0)) // extra field length
            header.append(name)
            return header
        }

        func centralDirectoryHeader() -> Data {
            var header = Data()
            header.appendLittleEndian(ZipArchive.centralDirectoryHeaderSignature)
            header.appendLittleEndian(Self.versionMadeBy)
            header.appendLittleEndian(method.versionNeeded)
            appendCommonFields(to: &header)
            header.appendLittleEndian(UInt16(0)) // extra field length
            header.appendLittleEndian(UInt16(0)) // comment length
            header.appendLittleEndian(UInt16(0)) // disk number start
            header.appendLittleEndian(UInt16(0)) // internal attributes
            // The external attributes: the UNIX file mode (file type and permissions) in their upper half, MS-DOS
            // attributes (none) in their lower half.
            header.appendLittleEndian(UInt32(Self.fileType.rawValue | Self.permissions.rawValue) << 16)
            header.appendLittleEndian(localHeaderOffset)
            header.append(name)
            return header
        }

        /// The fields from the flags through the name length, which both headers state alike.
        private func appendCommonFields(to header: inout Data) {
            header.appendLittleEndian(Self.flags.rawValue)
            header.appendLittleEndian(method.rawValue)
            header.appendLittleEndian(Self.modificationTime)
            header.appendLittleEndian(Self.modificationDate)
            header.appendLittleEndian(crc32)
            header.appendLittleEndian(compressedSize)
            header.appendLittleEndian(size)
            header.appendLittleEndian(nameLength)
        }
    }
}


extension ZipArchive {
    /// Reads little-endian fields from an archive, failing on any read past its end.
    private struct ByteReader {
        private let data: Data
        private var offset: Int

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

        mutating func read<Value: FixedWidthInteger>(_: Value.Type) throws -> Value {
            try read(byteCount: MemoryLayout<Value>.size).reversed().reduce(Value.zero) { $0 << 8 | Value($1) }
        }
    }
}


extension Data {
    fileprivate mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}


extension ZipArchive {
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
