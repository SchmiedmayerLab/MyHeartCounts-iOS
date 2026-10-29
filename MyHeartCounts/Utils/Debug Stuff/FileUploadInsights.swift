//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import Foundation
import GroveFoundation
import GroveViews
import SwiftUI


struct FileUploadInsights: View {
    @Environment(ManagedFileUpload.self)
    private var managedFileUpload
    /// When the queue was last reread: every two seconds, and at once when pulled down.
    @State private var refreshed = Date.now
    /// Each category's pending files' total size, as last read off the main actor.
    @State private var pendingSizes: [ManagedFileUpload.Category: Int64] = [:]
    
    @State private var detailsSheetCategory: ManagedFileUpload.Category?

    private var inactiveCategories: [ManagedFileUpload.Category] {
        managedFileUpload.categories.filter { category in
            if let progress = managedFileUpload.progressByCategory[category] {
                progress.isFinished
            } else {
                true
            }
        }
    }
    
    var body: some View {
        Form {
            ForEach(categoryInfos, id: \.category) { categoryInfo in
                row(for: categoryInfo)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack {
                    Text("ManagedFileUpload" as String)
                        .font(.headline)
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .standard))" as String)
                        .font(.subheadline)
                }
            }
        }
        .refreshable {
            await reloadPendingSizes()
            refreshed = .now
        }
        .task {
            // A category's `Progress` and its pending files' size change without notifying SwiftUI, so the queue
            // is reread every two seconds. Only a change of the view's own state rereads the rows; a
            // `TimelineView` tick redraws the timestamp but leaves them as they were.
            while !Task.isCancelled {
                await reloadPendingSizes()
                try? await Task.sleep(for: .seconds(2))
                refreshed = .now
            }
        }
        .sheet(item: $detailsSheetCategory) { category in
            CategoryDetailsSheet(category: category)
        }
    }
}


extension FileUploadInsights {
    private struct CategoryInfo: Equatable {
        let category: ManagedFileUpload.Category
        let progress: Progress?
        let totalPendingSizeInBytes: Int64?
        
        var isActive: Bool {
            guard let progress else {
                return false
            }
            return !(progress.isCancelled || progress.isPaused)
        }
    }
    
    private var categoryInfos: [CategoryInfo] {
        _ = refreshed
        return managedFileUpload.categories
            .map {
                CategoryInfo(
                    category: $0,
                    progress: managedFileUpload.progressByCategory[$0],
                    totalPendingSizeInBytes: pendingSizes[$0]
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.totalPendingSizeInBytes, rhs.totalPendingSizeInBytes) {
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case let (.some(lhsSize), .some(rhsSize)):
                    lhsSize > rhsSize || (lhsSize == rhsSize && lhs.category.id < rhs.category.id)
                case (.none, .none):
                    lhs.category.id < rhs.category.id
                }
            }
    }
    
    /// Rereads every category's pending files' total size, which the upload module reads off the main actor.
    private func reloadPendingSizes() async {
        var sizes: [ManagedFileUpload.Category: Int64] = [:]
        for category in managedFileUpload.categories {
            sizes[category] = await managedFileUpload.totalPendingFileSize(for: category)
        }
        pendingSizes = sizes
    }

    @ViewBuilder
    private func row(for categoryInfo: CategoryInfo) -> some View {
        Button {
            detailsSheetCategory = categoryInfo.category
        } label: {
            VStack(alignment: .leading) {
                Text(categoryInfo.category.title)
                    .font(.headline)
                if let progress = categoryInfo.progress {
                    VStack {
                        ProgressView(
                            value: Double(progress.completedUnitCount),
                            total: Double(max(progress.totalUnitCount, 1))
                        )
                        HStack {
                            Text("\(progress.completedUnitCount) / \(progress.totalUnitCount)" as String)
                            Spacer()
                            if let size = categoryInfo.totalPendingSizeInBytes {
                                Text(size, format: .byteCount(style: .file))
                            }
                        }
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    }
                }
            }
        }
        .foregroundStyle(.textLabel)
    }
}


extension FileUploadInsights {
    private struct CategoryDetailsSheet: View {
        @Environment(ManagedFileUpload.self)
        private var managedFileUpload
        
        let category: ManagedFileUpload.Category
        @State private var pendingFiles: [ManagedFileUpload.PendingFile] = []
        @State private var refreshTrigger = AsyncStream.makeStream(of: Void.self)
        
        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        ForEach(pendingFiles) { pendingFile in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(pendingFile.filename)
                                        .font(.caption2.monospaced())
                                    Text(pendingFile.state.displayText)
                                }
                                Spacer()
                                if let size = pendingFile.size {
                                    Text(size, format: .byteCount(style: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle(category.title)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        DismissButton()
                    }
                }
                .task {
                    await refreshFiles()
                    for await _ in refreshTrigger.stream {
                        await refreshFiles()
                    }
                }
                .refreshable {
                    refreshTrigger.continuation.yield()
                }
            }
        }
        
        private func refreshFiles() async {
            let compare: (ManagedFileUpload.PendingFile, ManagedFileUpload.PendingFile) -> Bool = { lhs, rhs in
                let lhsSize = lhs.size ?? 0
                let rhsSize = rhs.size ?? 0
                return lhsSize > rhsSize || lhs.filename < rhs.filename
            }
            pendingFiles = await managedFileUpload
                .pendingFiles(in: category)
                .grouped(by: \.state)
                .mapValues { $0.sorted(by: compare) }
                .sorted(using: KeyPathComparator(\.key.indexForSorting))
                .flatMap(\.value)
        }
    }
}


extension ManagedFileUpload.PendingFile.State {
    fileprivate var displayText: String {
        switch self {
        case .queued:
            "queued"
        case .uploading:
            "uploading"
        case .held:
            "held"
        case .waitingForRetry(let failedAttempts):
            "waiting for retry (#failed: \(failedAttempts))"
        case .idle:
            "idle"
        }
    }
    
    fileprivate var indexForSorting: Int {
        switch self {
        case .queued:
            1
        case .uploading:
            0
        case .held:
            4
        case .waitingForRetry:
            2
        case .idle:
            3
        }
    }
}


extension FileManager {
    func directorySize(at url: URL) throws -> Int64 {
        guard isDirectory(at: url) else {
            throw FileManagerError.other("Not a directory")
        }
        let resourceKeys: Set<URLResourceKey> = [.totalFileSizeKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = self.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: resourceKeys)
            if resourceValues.isDirectory == false {
                total += Int64(resourceValues.fileSize ?? 0)
            }
        }
        return total
    }
}
