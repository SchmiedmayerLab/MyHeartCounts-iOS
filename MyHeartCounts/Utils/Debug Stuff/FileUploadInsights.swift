//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziFoundation
import SwiftUI


struct FileUploadInsights: View {
    @Environment(ManagedFileUpload.self)
    private var managedFileUpload
    
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
            ForEach(Array(managedFileUpload.categories)) { category in
                if let progress = managedFileUpload.progressByCategory[category] {
                    Section {
                        ProgressView(progress)
                    } header: {
                        Text(category.title)
                    } footer: {
                        if let size = try? FileManager.default.directorySize(at: category.stagingDirUrl) {
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
