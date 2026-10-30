//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseStorage
import Foundation
import GroveAccount
import GroveConsent
import GroveFoundation
import GroveStudyDefinition
import OSLog
import PDFKit


extension MyHeartCountsStandard {
    enum ConsentUploadError: Error {
        case noAccount
        case unableToGetPDFData
        case unableToEncodeMetadata(underlyingError: any Error)
    }
    
    nonisolated static let consentDateFormat = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard, timeZone: .gmt)
    
    /// Uploads a consent document to Firebase.
    func uploadConsentDocument(_ exportResult: sending ConsentDocument.ExportResult) async throws {
        guard let accountId = await account?.details?.accountId else {
            logger.error("Unable to get account id. not uploading consent form.")
            throw ConsentUploadError.noAccount
        }
        guard let pdfData = exportResult.pdf.dataRepresentation() else {
            logger.error("Unable to get PDF data. not uploading consent form.")
            throw ConsentUploadError.unableToGetPDFData
        }
        let storageRef = Storage.storage().reference(withPath: "users/\(accountId)/consent/\(Int(Date.now.timeIntervalSince1970)).pdf")
        let metadata = StorageMetadata()
        metadata.contentType = "application/pdf"
        do {
            var customConsentMetadata: [String: String] = [
                // the metadata that was parsed from the consent markdown (ie, the frontmatter at the top)
                "consentFormMetadata": try JSONEncoder().encode(exportResult.metadata),
                // the responses provided by the user, to the interactive elements in the markdown
                "responses": try JSONEncoder().encode(exportResult.userResponses),
                "date": Date.now.ISO8601Format(Self.consentDateFormat)
            ]
            if let version = exportResult.metadata.version {
                customConsentMetadata["version"] = version.description
            }
            metadata.customMetadata = customConsentMetadata
        } catch {
            throw ConsentUploadError.unableToEncodeMetadata(underlyingError: error)
        }
        _ = try await storageRef.putDataAsync(pdfData, metadata: metadata)
    }
}


extension JSONEncoder {
    @_disfavoredOverload
    func encode(_ value: some Encodable) throws -> String {
        let data: Data = try self.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            // https://www.rfc-editor.org/rfc/rfc8259#section-8.1
            preconditionFailure("Unreachable; JSON is guaranteed to be UTF-8")
        }
        return string
    }
}

extension JSONDecoder {
    private enum CodingError: Error {
        case inputNotUTF8
    }
    
    @_disfavoredOverload
    func decode<T: Decodable>(_ ty: T.Type, from input: String) throws -> T { // swiftlint:disable:this identifier_name
        guard let data = input.data(using: .utf8) else {
            throw CodingError.inputNotUTF8
        }
        return try decode(ty, from: data)
    }
}
