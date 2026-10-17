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
/// - `bundles.json`: a JSON array of the records' FHIR Bundles, each spliced in verbatim, in the order they were added.
/// - `recordings/<name>`: each recording a Bundle references, at the path relative to the archive's root that the Bundle
///     states (see ``recordingPath(forName:)``).
///
/// Records are added one at a time: each record's recording is written to the archive's file right away, while its
/// Bundle is kept until ``finalize()`` writes `bundles.json` and `batchinfo.json`. An archive that is not finalized
/// removes its file. Every entry is compressed with Zstandard, unless that would not make it smaller.
///
/// ``Reader`` reads an archive back.
public struct UploadBatchArchive: ~Copyable {
    /// A recording a record's Bundle references.
    public struct Recording: Hashable, Sendable {
        /// The recording's file name within the archive's `recordings/` directory.
        public let name: String
        /// The recording's exact bytes.
        public let contents: Data

        public init(name: String, contents: Data) {
            self.name = name
            self.contents = contents
        }
    }

    public enum FormatError: Error, Equatable {
        /// The archive lacks an entry its format requires.
        case missingEntry(path: String)
        /// The archive is of a format version this reader does not know.
        case unsupportedFormatVersion(UInt)
    }

    private static let batchInfoPath = "batchinfo.json"
    private static let bundlesPath = "bundles.json"
    private static let recordingsDirectory = "recordings/"
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
    /// The `bundles.json` array, as far as the records added so far fill it.
    private var bundles = Data("[".utf8)

    /// Creates an empty archive in a temporary file, for records of one sample type.
    ///
    /// - parameter device: The device that produced the batch's records (e.g., `Watch7,12`), if one did.
    public init(source: BatchInfo.Source, sampleTypeId: String, device: String?) throws {
        let url = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).zip")
        info = .init(source: source, sampleTypeId: sampleTypeId, startDate: nil, endDate: nil, numRecords: 0, numSamples: 0, device: device)
        archive = try ZipArchive(writingTo: url)
        self.url = url
    }

    /// The path, relative to the archive's root, of the recording named `name`: the path the Bundle that references
    /// the recording must state.
    public static func recordingPath(forName name: String) -> String {
        recordingsDirectory + name
    }

    /// Adds one record: its Bundle, the recording the Bundle references, if any, and the facts the batch info sums up.
    ///
    /// - parameter bundle: The record's FHIR Bundle, as JSON, which is written verbatim.
    /// - parameter recording: The recording the Bundle references, under the path ``recordingPath(forName:)`` gives
    ///     for its name.
    /// - parameter timeRange: The time span the record's samples cover.
    /// - parameter sampleCount: The number of samples the record holds.
    public mutating func addRecord(
        bundle: Data,
        recording: Recording? = nil,
        timeRange: Range<Date>,
        sampleCount: Int
    ) throws {
        if let recording {
            try archive.addEntry(at: Self.recordingPath(forName: recording.name), contents: recording.contents, compression: .zstd)
        }
        if info.numRecords > 0 {
            bundles.append(UInt8(ascii: ","))
        }
        bundles.append(bundle)
        info.startDate = min(info.startDate ?? timeRange.lowerBound, timeRange.lowerBound)
        info.endDate = max(info.endDate ?? timeRange.upperBound, timeRange.upperBound)
        info.numRecords += 1
        info.numSamples += sampleCount
    }

    /// Writes `bundles.json` and `batchinfo.json`, and completes the archive.
    ///
    /// - returns: The archive's file, in a temporary directory; the caller takes it over.
    public consuming func finalize() throws -> URL {
        bundles.append(UInt8(ascii: "]"))
        try archive.addEntry(at: Self.bundlesPath, contents: bundles, compression: .zstd)
        try archive.addEntry(at: Self.batchInfoPath, contents: Self.encoder.encode(info), compression: .zstd)
        try archive.finalize()
        return url
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
//        source    sensorkit    healthkit
//        sampleType    com.apple.SensorKit.accelerometer    HKQuantityTypeIdentifierHeartRate
//        start, end    the batch’s time range    min/max of the samples’ dates
//        recordCount    bundles in the archive    bundles in the archive
//        sampleCount    samples across records (a CSV record holds many)    same as recordCount
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
        /// The paths of the batch's recordings, relative to the archive's root, as the Bundles that reference them state.
        public let recordingPaths: [String]
        private let archive: ZipArchive.Reader

        /// Reads the archive at `url`.
        public init(contentsOf url: URL) throws {
            try self.init(archive: ZipArchive.Reader(contentsOf: url))
        }

        /// Reads the archive `data` holds.
        public init(_ data: Data) throws {
            try self.init(archive: ZipArchive.Reader(data))
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
            self.recordingPaths = archive.entries.map(\.path).filter { $0.hasPrefix(UploadBatchArchive.recordingsDirectory) }
            self.archive = archive
        }

        private static func contents(at path: String, in archive: ZipArchive.Reader) throws -> Data {
            guard let entry = archive.entries.first(where: { $0.path == path }) else {
                throw FormatError.missingEntry(path: path)
            }
            return try archive.contents(of: entry)
        }

        /// The batch's Bundles: the contents of `bundles.json`, a JSON array of them.
        public func bundles() throws -> Data {
            try Self.contents(at: UploadBatchArchive.bundlesPath, in: archive)
        }

        /// The recording at `path`, one of the ``recordingPaths``.
        public func recording(at path: String) throws -> Data {
            try Self.contents(at: path, in: archive)
        }
    }
}
