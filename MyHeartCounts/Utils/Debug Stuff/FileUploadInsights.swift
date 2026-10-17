//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import SwiftUI


struct FileUploadInsights: View {
    @Environment(ManagedFileUpload.self)
    private var managedFileUpload
    /// When the queue was last reread: every two seconds, and at once when pulled down.
    @State private var refreshed = Date.now

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
        form
            .refreshable {
                refreshed = .now
            }
            .task {
                // A category's `Progress` and its pending files' size change without notifying SwiftUI, so the queue
                // is reread every two seconds. Only a change of the view's own state rereads the rows; a
                // `TimelineView` tick redraws the timestamp but leaves them as they were.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    refreshed = .now
                }
            }
    }

    private var form: some View {
        Form {
            Section {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .standard))" as String)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(managedFileUpload.categories)) { category in
                if let progress = managedFileUpload.progressByCategory[category] {
                    Section {
                        ProgressView(
                            value: Double(progress.completedUnitCount),
                            total: Double(max(progress.totalUnitCount, 1))
                        ) {
                            Text("\(progress.completedUnitCount) of \(progress.totalUnitCount) uploaded" as String)
                        }
                    } header: {
                        Text(category.title)
                    } footer: {
                        if let size = managedFileUpload.totalPendingFileSize(for: category) {
                            let size = size.formatted(.byteCount(style: .file))
                            Text("Total Size: \(size)" as String)
                        }
                    }
                }
            }
            Section("Inactive / Complete" as String) {
                ForEach(inactiveCategories) { category in
                    Text(category.title)
                }
            }
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
