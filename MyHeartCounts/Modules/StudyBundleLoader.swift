//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseCore
import Foundation
import MHCStudyDefinitionExporter
import MyHeartCountsShared
import OSLog
import Spezi
import SpeziFoundation
import SpeziStudyDefinition
import Synchronization
import UniformTypeIdentifiers


@Observable
final class StudyBundleLoader: Module, Sendable {
    enum LoadError: Error {
        case unableToFetchFromServer(any Error)
        case unableToDecode(any Error)
        case noLastUsedFirebaseConfig
        case unableToCreateLocalBundle(any Error)
    }
    
    static let shared = StudyBundleLoader()
    
    private let logger = Logger(category: .init("StudyLoader"))
    
    /// The currently active Study Bundle loading operation, if any.
    ///
    /// This exists to avoid performing multiple, concurrent downloads of the bundle.
    ///
    /// - Note: we use the Result in here, and set the Task's Failure type to Never, since Task currently only supports type-erased `any Error` failures.
    ///     (and does not support typed throws in its init, for whatever reason...)
    @ObservationIgnored @MainActor private var loadStudyBundleTask: Task<Result<StudyBundle, LoadError>, Never>?
    
    @ObservationIgnored private let _studyBundle = Mutex<Result<StudyBundle, LoadError>?>(nil)
    
    var studyBundle: Result<StudyBundle, LoadError>? {
        access(keyPath: \.studyBundle)
        return _studyBundle.withLock { $0 }
    }
    
    // SAFETY: the FileManager type itself is not thread safe,
    // but we have our own instance (as opposed to using `FileManager.default`), and we never mutate it.
    nonisolated(unsafe) private let fileManager = FileManager()
    
    /// The url where we store the `StudyBundle`s downloaded by the Loader.
    ///
    /// Note that this is distinct from what the `StudyManager`' does, which also stores the `StudyBundle`s of the study(/studies) we're enrolled into, in a special directory.
    private let studyBundlesUrl: URL
    
    private init() {
        studyBundlesUrl = URL.documentsDirectory.appending(path: "MHC/StudyBundlesCache", directoryHint: .isDirectory)
        Task {
            _ = try? await update()
        }
        Task(priority: .background) {
            try? await cleanupOldStudyBundles()
        }
    }
    
    
    private func _storeStudyBundleResult(
        _ newValue: Result<StudyBundle, LoadError>,
        preferCachedBundleOnError: Bool
    ) -> Result<StudyBundle, LoadError> {
        _studyBundle.withLock { value in
            switch (value, newValue) {
            case (.none, let newValue):
                withMutation(keyPath: \.studyBundle) {
                    value = newValue
                }
                return newValue
            case (.some(.failure), let newValue):
                withMutation(keyPath: \.studyBundle) {
                    value = newValue
                }
                return newValue
            case (.some(.success(let oldBundle)), .success(let newBundle)):
                if newBundle != oldBundle {
                    withMutation(keyPath: \.studyBundle) {
                        value = .success(newBundle)
                    }
                    return newValue
                } else {
                    return .success(oldBundle)
                }
            case (.some(.success(let oldBundle)), .failure):
                // in this case (we successfully obtained a study bundle before, but it now has failed),
                // we keep the old bundle around instead of updating `_studyBundle` with the error case.
                if preferCachedBundleOnError {
                    return .success(oldBundle)
                } else {
                    withMutation(keyPath: \.studyBundle) {
                        value = newValue
                    }
                    return newValue
                }
            }
        }
    }
    
    /// Updates the study bundle.
    ///
    /// - parameter returnCachedBundleOnError: Whether, if the update fails, and there still exists an old stucy bundle that was fetched earlier, that one should be returned, instead of the update failing. Defaults to `true`.
    @discardableResult
    @MainActor
    func update(
        returnCachedBundleOnError: Bool = true
    ) async throws(LoadError) -> StudyBundle {
        if let loadStudyBundleTask {
            // we need to do `.result.get()` here, instead of a simple `.value`, since the throw in the later case isn't typed.
            return try await loadStudyBundleTask.result.get().get()
        }
        let task = Task<Result<StudyBundle, LoadError>, Never> {
            var result: Result<StudyBundle, LoadError>
            do throws(LoadError) {
                result = .success(try await _update(
                    using: LaunchOptions.launchOptions[.studyBundleSelector]
                ))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                result = _storeStudyBundleResult(result, preferCachedBundleOnError: returnCachedBundleOnError)
                self.loadStudyBundleTask = nil
            }
            return result
        }
        self.loadStudyBundleTask = task
        return try await task.result.get().get()
    }
    
    
    private func _update(using selector: StudyBundleSelector) async throws(LoadError) -> StudyBundle {
        let studyBundleArchiveUrl: URL
        switch selector {
        case .firebase:
            if let selector = FeatureFlags.overrideFirebaseConfig ?? LocalPreferencesStore.standard[.lastUsedFirebaseConfig],
               let options = try? DeferredConfigLoading.firebaseOptions(for: selector),
               let bucket = options.storageBucket {
                studyBundleArchiveUrl = Self.url(ofFile: "mhcStudyBundle.\(StudyBundle.fileExtension).aar", inBucket: bucket)
            } else {
                logger.error("No last-used firebase config.")
                throw .noLastUsedFirebaseConfig
            }
        case .atUrl(let url):
            studyBundleArchiveUrl = url
        case .bundledWithApp:
            do {
                studyBundleArchiveUrl = try export(to: .temporaryDirectory, as: .archive)
            } catch {
                throw .unableToCreateLocalBundle(error)
            }
        }
        let downloadUrl: URL
        do {
            downloadUrl = try await download(studyBundleArchiveUrl)
        } catch {
            throw LoadError.unableToFetchFromServer(error)
        }
        do {
            return try await openDownloadedStudyBundle(at: downloadUrl)
        } catch LoadError.unableToDecode where selector == .firebase {
            // if we failed to decode the firebase-hosted study bundle, we try to use the bundled one as a fallback.
            // (otherwise, we simply propagate the error up the call stack.)
            return try await _update(using: .bundledWithApp)
        }
    }
    
    
    private func openDownloadedStudyBundle(at url: URL) async throws(LoadError) -> StudyBundle {
        let tmpUrl = URL.temporaryDirectory.appending(component: UUID().uuidString).appendingPathExtension("\(StudyBundle.fileExtension).aar")
        let dstUrl = self.studyBundlesUrl.appendingPathComponent(UUID().uuidString, conformingTo: .speziStudyBundle)
        do {
            try fileManager.copyItem(at: url, to: tmpUrl, overwriteExisting: true)
            defer {
                try? fileManager.removeItem(at: tmpUrl)
            }
            try fileManager.unarchiveDirectory(at: tmpUrl, to: dstUrl)
        } catch {
            throw .unableToFetchFromServer(error)
        }
        do {
            return try StudyBundle(bundleUrl: dstUrl)
        } catch {
            logger.error("Error opening StudyBundle: \(error)")
            throw .unableToDecode(error)
        }
    }
    
    
    // periphery:ignore - unused but we want to keep it should we want/need to download additional resources in the future.
    /// Downloads the file with the specified `filename` from the Firebase Storage bucket `bucketName`
    @discardableResult
    func download(fileName: String, inBucket bucketName: String) async throws -> URL {
        try await download(Self.url(ofFile: fileName, inBucket: bucketName))
    }
    
    @discardableResult
    private func download(_ url: URL) async throws -> URL {
        logger.notice("will try to download '\(url.absoluteString)'")
        let session = URLSession(configuration: .ephemeral)
        let (downloadUrl, response) = try await session.download(from: url)
        logger.notice("did finish download of '\(url.lastPathComponent)'")
        guard let response = response as? HTTPURLResponse else {
            guard !url.isFileURL else {
                // we were "downloading" a local file, so it's expected that we don't get back a HTTPURLResponse
                return downloadUrl
            }
            throw NSError(domain: "edu.stanford.MHC", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Unable to decode HTTP response"
            ])
        }
        switch response.statusCode {
        case 200:
            return downloadUrl
        case 404:
            throw NSError(domain: "edu.stanford.MHC", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Unable to find file '\(url)'"
            ])
        default:
            throw NSError(domain: "edu.stanford.MHC", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Unable to fetch file '\(url)'"
            ])
        }
    }
    
    private func cleanupOldStudyBundles() async throws {
        struct Entry {
            let url: URL
            let creationDate: Date
            init?(url: URL) {
                guard let creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else {
                    return nil
                }
                self.url = url
                self.creationDate = creationDate
            }
        }
        
        let entries = try fileManager
            .contents(of: studyBundlesUrl, includingPropertiesForKeys: [.creationDateKey])
            .compactMap { Entry(url: $0) }
            .sorted(using: KeyPathComparator(\.creationDate))
        for entry in entries.dropLast() {
            try fileManager.removeItem(at: entry.url)
        }
    }
}


extension StudyBundleLoader {
    private static func url(ofFile filename: String, inBucket bucketName: String) -> URL {
        "https://firebasestorage.googleapis.com/v0/b/\(bucketName)/o/public%2F\(filename)?alt=media"
    }
}
