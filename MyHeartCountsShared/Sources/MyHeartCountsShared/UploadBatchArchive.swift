//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

public import Foundation


/// A batch of exported health data records, packaged for upload as one ZIP archive.
///
/// The archive's layout (``BatchInfo/formatVersion`` 1):
/// - `batchinfo.json`: the batch's ``BatchInfo``, which sums up the records it holds.
/// - `bundle.json`: the one FHIR Bundle that holds every record, verbatim.
/// - `recordings/<name>`: each sensor recording the Bundle references, and `documents/<name>`: each file a clinical record
///     carries, at the path relative to the archive's root that the Bundle states (see ``path(forName:in:)``).
///
/// Records are added one at a time: each record's recordings are written to the archive's file right away, and
/// ``finalize(bundle:)`` writes `bundle.json` and `batchinfo.json`. An archive that is not finalized removes its file.
/// Every entry held in memory is compressed with Zstandard, unless that would not make it smaller; a recording read from a
/// file is streamed in and stored as it is, so the archive holds a file of any size without holding it in memory.
///
/// The same records, added in the same order, and the same Bundle always produce the same entries. The archive's
/// compressed bytes are the same only under the same version of Zstandard, which guarantees reproducible output within a
/// release only; an archive rebuilt after an update may differ from an earlier one byte for byte while holding the same
/// entries.
///
/// ``Reader`` reads an archive back.
public struct UploadBatchArchive: ~Copyable {
    /// A recording the Bundle references.
    public struct Recording: Hashable, Sendable {
        /// The archive directory a recording is in.
        public enum Directory: String, CaseIterable, Hashable, Sendable {
            /// A sensor recording, such as SensorKit samples.
            case recordings = "recordings/"
            /// A file a clinical record carries, such as a clinical note's PDF.
            case documents = "documents/"
        }

        /// Where a recording's exact bytes are.
        public enum Source: Hashable, Sendable {
            /// The bytes, in memory.
            case contents(Data)
            /// The file holding the bytes, which is read when the recording is added to an archive.
            case file(URL)
        }

        /// The recording's file name within its ``directory``.
        public let name: String
        /// The archive directory the recording is in.
        public let directory: Directory
        /// Where the recording's exact bytes are.
        public let source: Source

        /// The recording's path relative to the archive's root.
        public var path: String {
            UploadBatchArchive.path(forName: name, in: directory)
        }

        /// A recording of `contents`, held in memory.
        public init(name: String, in directory: Directory = .recordings, contents: Data) {
            self.name = name
            self.directory = directory
            self.source = .contents(contents)
        }

        /// A recording of the bytes of the file at `url`, which must stay in place until the recording is added.
        public init(name: String, in directory: Directory = .recordings, fileAt url: URL) {
            self.name = name
            self.directory = directory
            self.source = .file(url)
        }
    }

    public enum FormatError: Error, Equatable {
        /// The archive lacks an entry its format requires.
        case missingEntry(path: String)
        /// The archive is of a format version this reader does not know.
        case unsupportedFormatVersion(UInt)
    }

    private static let batchInfoPath = "batchinfo.json"
    private static let bundlePath = "bundle.json"
    /// The deterministic JSON the batch info is written as: sorted keys, and every date as an ISO 8601 instant in UTC,
    /// with its fractional seconds.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .formatStyle(UploadBatchArchive.dateFormat)
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatStyle(UploadBatchArchive.dateFormat)
        return decoder
    }()
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private var info: BatchInfo
    private let url: URL
    private var archive: ZipArchive
    /// The paths of the recordings written so far.
    private var recordingPaths: Set<String> = []

    /// Creates an empty archive in a temporary file, for records of one sample type.
    ///
    /// - parameter device: The device that produced the batch's records (e.g., `Watch7,12`), if one did.
    public init(source: BatchInfo.Source, sampleTypeId: String, device: String?) throws {
        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).zip")
        info = .init(source: source, sampleTypeId: sampleTypeId, startDate: nil, endDate: nil, numRecords: 0, numSamples: 0, device: device)
        archive = try ZipArchive(writingTo: url)
        self.url = url
    }

    /// The path, relative to the archive's root, of the recording named `name` in `directory`: the path the Bundle that
    /// references the recording must state.
    public static func path(forName name: String, in directory: Recording.Directory) -> String {
        directory.rawValue + name
    }

    /// Adds one record: the recording the Bundle references for it, if any, and the facts the batch info sums up.
    ///
    /// A recording path is written once: equal paths hold equal bytes, and byte-identical records at two coordinates
    /// are legal, so the second record's recording is the first's.
    ///
    /// - parameter recording: The recording the Bundle references, under its ``Recording/path``.
    /// - parameter timeRange: The time span the record's samples cover.
    /// - parameter sampleCount: The number of samples the record holds.
    public mutating func addRecord(
        recording: Recording? = nil,
        timeRange: Range<Date>,
        sampleCount: Int
    ) throws {
        try addRecord(recordings: recording.map { [$0] } ?? [], timeRange: timeRange, sampleCount: sampleCount)
    }

    /// Adds one record: every recording the Bundle references for it, in order, and the facts the batch info sums up.
    ///
    /// A recording path is written once: equal paths hold equal bytes, so a recording two records, or one record twice,
    /// reference is written for the first.
    ///
    /// - parameter recordings: The recordings the Bundle references for the record, each under its ``Recording/path``.
    /// - parameter timeRange: The time span the record's samples cover.
    /// - parameter sampleCount: The number of samples the record holds.
    public mutating func addRecord(
        recordings: [Recording],
        timeRange: Range<Date>,
        sampleCount: Int
    ) throws {
        for recording in recordings where recordingPaths.insert(recording.path).inserted {
            let path = recording.path
            switch recording.source {
            case .contents(let contents):
                try archive.addEntry(at: path, contents: contents, compression: .zstd)
            case .file(let url):
                try archive.addEntry(at: path, contentsOf: url)
            }
        }
        info.startDate = min(info.startDate ?? timeRange.lowerBound, timeRange.lowerBound)
        info.endDate = max(info.endDate ?? timeRange.upperBound, timeRange.upperBound)
        info.numRecords += 1
        info.numSamples += sampleCount
    }

    /// Writes `bundle.json` and `batchinfo.json`, and completes the archive.
    ///
    /// - parameter bundle: The FHIR Bundle of every record added, as JSON, which is written verbatim.
    public consuming func finalize(bundle: Data) throws -> Finalized {
        let batchInfo = try Self.encoder.encode(info)
        try archive.addEntry(at: Self.bundlePath, contents: bundle, compression: .zstd)
        try archive.addEntry(at: Self.batchInfoPath, contents: batchInfo, compression: .zstd)
        try archive.finalize()
        return Finalized(url: url, batchInfo: batchInfo)
    }
}


extension UploadBatchArchive {
    /// The finalized archive.
    public struct Finalized {
        /// The archive's file, in a temporary directory.
        public let url: URL
        /// The exact bytes of the batch's `batchinfo.json`.
        public let batchInfo: Data
    }
}


extension UploadBatchArchive {
    public struct BatchInfo: Codable, Hashable, Sendable {
        public struct Source: RawRepresentable, Codable, Hashable, Sendable {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// Batch info format version
        public let formatVersion: UInt
        /// Batch Source
        public let source: Source
        /// The batch's sample type.
        ///
        /// All samples/records contained w/in the batch must be of this sample type.
        public let sampleTypeId: String
        /// The batch's samples' min start date.
        public fileprivate(set) var startDate: Date?
        /// The batch's samples' max end date.
        public fileprivate(set) var endDate: Date?
        /// The number of records contained in the batch.
        public fileprivate(set) var numRecords: Int
        /// The number of samples contained across all the batch's records.
        public fileprivate(set) var numSamples: Int
        /// Info about the device that produced the batch (e.g., `Watch7,12`)
        public let device: String?

        fileprivate init(
            source: Source,
            sampleTypeId: String,
            startDate: Date?,
            endDate: Date?,
            numRecords: Int,
            numSamples: Int,
            device: String?
        ) {
            self.formatVersion = 1
            self.source = source
            self.sampleTypeId = sampleTypeId
            self.startDate = startDate
            self.endDate = endDate
            self.numRecords = numRecords
            self.numSamples = numSamples
            self.device = device
        }

//        Field    SensorKit    HealthKit
//        formatVersion    1    1
//        source    com.apple.SensorKit    com.apple.HealthKit
//        sampleTypeId    com.apple.SensorKit.accelerometer    HKQuantityTypeIdentifierHeartRate
//        startDate, endDate    the batch’s time range    min/max of the samples’ dates
//        numRecords    records in the archive’s Bundle    records in the archive’s Bundle
//        numSamples    samples across records (a CSV record holds many)    same as numRecords
//        device    the batch’s product type, e.g. Watch7,12    (omitted)
    }
}


extension UploadBatchArchive.BatchInfo.Source {
    /// Records exported from HealthKit samples.
    public static let healthKit = Self(rawValue: "com.apple.HealthKit")
    /// Records exported from SensorKit samples.
    public static let sensorKit = Self(rawValue: "com.apple.SensorKit")
}


// MARK: Reading

extension UploadBatchArchive {
    /// Reads an upload batch archive one part at a time: creating a reader reads only the batch info, and each other part
    /// is read when it is asked for.
    public struct Reader {
        /// The batch's info.
        public let info: BatchInfo
        /// The paths of the batch's recordings in every ``Recording/Directory``, relative to the archive's root, as the
        /// Bundle that references them states.
        public let recordingPaths: [String]
        private let archive: ZipArchive.Reader

        /// Reads the archive at `url`, refusing to decompress any part larger than `maximumEntrySize`.
        public init(contentsOf url: URL, maximumEntrySize: Int = ZipArchive.Reader.defaultMaximumEntrySize) throws {
            try self.init(archive: ZipArchive.Reader(contentsOf: url, maximumEntrySize: maximumEntrySize))
        }

        /// Reads the archive `data` holds, refusing to decompress any part larger than `maximumEntrySize`.
        public init(_ data: Data, maximumEntrySize: Int = ZipArchive.Reader.defaultMaximumEntrySize) throws {
            try self.init(archive: ZipArchive.Reader(data, maximumEntrySize: maximumEntrySize))
        }

        private init(archive: ZipArchive.Reader) throws {
            let info = try UploadBatchArchive.decoder.decode(
                BatchInfo.self,
                from: try Self.contents(at: UploadBatchArchive.batchInfoPath, in: archive)
            )
            guard info.formatVersion == 1 else {
                throw FormatError.unsupportedFormatVersion(info.formatVersion)
            }
            self.info = info
            self.recordingPaths = archive.entries.map(\.path).filter { path in
                Recording.Directory.allCases.contains { path.hasPrefix($0.rawValue) }
            }
            self.archive = archive
        }

        private static func contents(at path: String, in archive: ZipArchive.Reader) throws -> Data {
            guard let entry = archive.entries.first(where: { $0.path == path }) else {
                throw FormatError.missingEntry(path: path)
            }
            return try archive.contents(of: entry)
        }

        /// The batch's Bundle: the contents of `bundle.json`.
        public func bundle() throws -> Data {
            try Self.contents(at: UploadBatchArchive.bundlePath, in: archive)
        }

        /// The recording at `path`, one of the ``recordingPaths``.
        public func recording(at path: String) throws -> Data {
            try Self.contents(at: path, in: archive)
        }
    }
}
