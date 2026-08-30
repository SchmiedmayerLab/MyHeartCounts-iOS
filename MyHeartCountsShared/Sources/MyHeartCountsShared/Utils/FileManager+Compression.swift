//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if canImport(AppleArchive)

import AppleArchive
public import Foundation
import GroveFoundation
import System


extension FileManager {
    public struct ArchiveOperationError: LocalizedError {
        let message: String
        let underlyingError: (any Error)?
        
        public var errorDescription: String? {
            if let underlyingError {
                "\(message): \(underlyingError)"
            } else {
                message
            }
        }
        
        init(_ message: String, underlyingError: (any Error)? = nil) {
            self.message = message
            self.underlyingError = underlyingError
        }
    }
    
    // periphery:ignore - API
    /// Archives the contents of the directory.
    public func archiveDirectory(at srcUrl: URL, to dstUrl: URL) throws(ArchiveOperationError) {
        let sourcePath = FilePath(srcUrl.path)
        let destinationPath = FilePath(dstUrl.path)
        
        guard let writeFileStream = ArchiveByteStream.fileStream(
            path: destinationPath,
            mode: .writeOnly,
            options: [.create],
            permissions: FilePermissions(rawValue: 0o644)
        ) else {
            throw ArchiveOperationError("Unable to create writeFileStream")
        }
        defer {
            try? writeFileStream.close()
        }
        
        guard let compressionStream = ArchiveByteStream.compressionStream(
            using: .lzfse,
            writingTo: writeFileStream
        ) else {
            throw ArchiveOperationError("Unable to create compressionStream")
        }
        defer {
            try? compressionStream.close()
        }
        
        guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressionStream) else {
            throw ArchiveOperationError("Unable to create encodeStream")
        }
        defer {
            try? encodeStream.close()
        }
        
        guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM") else {
            throw ArchiveOperationError("Unable to create keySet")
        }
        
        do {
            try encodeStream.writeDirectoryContents(
                archiveFrom: sourcePath,
                keySet: keySet
            )
        } catch {
            throw ArchiveOperationError("Unable to write directory contents to file", underlyingError: error)
        }
    }
    
    
    /// Unarchives a directory archive that was created with `-lk_archiveDirectory`.
    ///
    /// - Warning: this function will unconditionally override the contents of the destination folder.
    public func unarchiveDirectory(at archiveUrl: URL, to dstUrl: URL) throws(ArchiveOperationError) { // swiftlint:disable:this function_body_length
        // See: https://developer.apple.com/documentation/accelerate/decompressing_and_extracting_an_archived_directory
        guard archiveUrl.pathExtension == "aar" else {
            throw ArchiveOperationError("Invalid path extension ('\(archiveUrl.pathExtension)')")
        }
        guard let dstFilePath = FilePath(dstUrl) else {
            throw ArchiveOperationError("Unable to create dstFilePath")
        }
        
        do {
            if itemExists(at: dstUrl) {
                try removeItem(at: dstUrl)
            }
            try createDirectory(at: dstUrl, withIntermediateDirectories: true)
        } catch {
            throw ArchiveOperationError("Failed to prepare destination directory", underlyingError: error)
        }
        
        guard let archiveFilePath = FilePath(archiveUrl) else {
            throw ArchiveOperationError("Unable to create FilePath for archive file")
        }
        
        guard let readFileStream = ArchiveByteStream.fileStream(
            path: archiveFilePath,
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)
        ) else {
            throw ArchiveOperationError("Unable to create readFileStream")
        }
        defer {
            try? readFileStream.close()
        }
        
        guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readFileStream) else {
            throw ArchiveOperationError("Unable to create decompressStream")
        }
        defer {
            try? decompressStream.close()
        }
        
        guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream) else {
            throw ArchiveOperationError("Unable to create decodeStream")
        }
        defer {
            try? decodeStream.close()
        }
        
        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: dstFilePath,
            flags: [.ignoreOperationNotPermitted]
        ) else {
            throw ArchiveOperationError("Unable to create extractStream")
        }
        defer {
            try? extractStream.close()
        }
        
        do {
            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            throw ArchiveOperationError("Unarchiving failed", underlyingError: error)
        }
    }
}

#endif
