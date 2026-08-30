//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseStorage
import Foundation
import Grove
import GroveFoundation
import GroveLocalization
import GroveStudy
import OSLog
import func QuartzCore.CACurrentMediaTime
import UniformTypeIdentifiers


@Observable
@MainActor
final class NewsManager: Module, EnvironmentAccessible {
    // swiftlint:disable attributes
    @ObservationIgnored @Application(\.logger) private var logger
    @ObservationIgnored @Dependency(StudyManager.self) private var studyManager
    // swiftlint:enable attributes
    
    private(set) var articles: [Article] = []
    private(set) var loadingError: (any Error)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    
    func configure() {
        Task {
            await refresh()
        }
    }
    
    
    func refresh() async { // swiftlint:disable:this function_body_length
        if let refreshTask {
            await refreshTask.value
            return
        }
        let logger = logger
        let refreshTask = Task { // swiftlint:disable:this closure_body_length
            defer {
                self.refreshTask = nil
            }
            let startTS = CACurrentMediaTime()
            defer {
                let endTS = CACurrentMediaTime()
                logger.trace("TOTAL TIME SPENT FETCHING AND PROCESSING NEWS: \(endTS - startTS)")
            }
            let locale = studyManager.preferredLocale
            let storage = Storage.storage()
            let newsFolder = storage.reference(withPath: "/public/news/")
            guard let newsArticleFiles = try? await newsFolder.listAll() else {
                return
            }
            logger.trace("TIME SPENT FETCHING FILEREFS: \(CACurrentMediaTime() - startTS)")
            for fileRef in newsArticleFiles.items {
                self.logger.notice("- \(fileRef.fullPath)")
            }
            let newsArticleStorageRefs = newsArticleFiles.items
                .reduce(into: [String: [StorageReference]]()) { mapping, storageRef in
                    let url = URL(filePath: storageRef.fullPath).absoluteURL
                    guard let fileInfo = LocalizedFileResolution.parse(url) else {
                        self.logger.notice("Skipping news articles file \(storageRef) bc we were unable to extract the filename.")
                        return
                    }
                    mapping[fileInfo.unlocalizedUrl.lastPathComponent, default: []].append(storageRef)
                }
                .compactMap { filename, storageRefs -> StorageReference? in
                    let urls = storageRefs.map { URL(filePath: $0.fullPath).absoluteURL }
                    guard let result = LocalizedFileResolution.resolve(
                        LocalizedFileResource(filename, locale: locale),
                        from: urls,
                        using: .preferLanguageMatch,
                        fallback: .enUS
                    ) else {
                        return nil
                    }
                    return storageRefs.first(where: { $0.name == result.url.lastPathComponent })
                }
            var articles = await withTaskGroup(of: Article?.self, returning: [Article].self) { taskGroup in
                for storageRef in newsArticleStorageRefs {
                    taskGroup.addTask {
                        do {
                            let tmpUrl = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, conformingTo: .plainText)
                            let startTS = CACurrentMediaTime()
                            _ = try await storageRef.writeAsync(toFile: tmpUrl)
                            let endTS = CACurrentMediaTime()
                            logger.trace("DOWNLOAD DURATION: \(endTS - startTS)")
                            let doc = try MarkdownDocument(contentsOf: tmpUrl)
                            try? FileManager.default.removeItem(at: tmpUrl)
                            let article = Article(id: doc.metadata["id"].flatMap(UUID.init(uuidString:)) ?? UUID(), doc)
                            return article.status == .published ? article : nil
                        } catch {
                            logger.error("Error processing news article: \(error)")
                            return nil
                        }
                    }
                }
                var articles: [Article] = []
                for await article in taskGroup {
                    if let article {
                        articles.append(article)
                    }
                }
                return articles
            }
            articles.removeAll(where: { $0.date == nil })
            // SAFETY: we do a force unwrap here, but we've just removed all articles that have a nil `date`.
            articles.sort(using: KeyPathComparator(\.date!, order: .reverse))
            self.articles = articles
        }
        self.refreshTask = refreshTask
        await refreshTask.value
    }
}
