//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable all

import Foundation
import SpeziFoundation
import SwiftUI
import UniformTypeIdentifiers


struct FileBrowser: View {
    private let url: URL
    
    @DirectoryQuery private var dirContents: [URL]
    
    var body: some View {
        Form {
            if FileManager.default.isDirectory(at: url) {
                ForEach(dirContents, id: \.self) { url in
                    makeRow(for: url)
                }
            } else {
                Text(verbatim: "TODO: file info for \(url)")
            }
        }
    }
    
    init(url: URL) {
        self.url = url
        self._dirContents = .init(url: url)
    }
    
    @ViewBuilder
    private func makeRow(for url: URL) -> some View {
        NavigationLink {
            FileBrowser(url: url)
        } label: {
            HStack {
                // TODO thumbnail (we have this in LLMonFHIR/SpeziViews!)
                VStack(alignment: .leading) {
                    Text(url.lastPathComponent)
                    HStack {
                        ForEach(info(for: url), id: \.self) { elem in
                            Text(elem)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
        }
    }
    
    private func info(for url: URL) -> [String] {
        let resourceValues = (try? url.resourceValues(forKeys: DirectoryQuery.resourceValueKeys)) ?? .init()
        let pieces: [String?] = [
            resourceValues.fileSize?.formatted(.byteCount(style: .file)),
            resourceValues.contentType?.identifier
        ]
        return pieces.compactMap(\.self)
    }
}


@propertyWrapper
private struct DirectoryQuery: DynamicProperty {
    fileprivate static let resourceValueKeys: Set<URLResourceKey> = [
        .fileSizeKey, .fileSecurityKey,
        .creationDateKey, .contentAccessDateKey, .contentModificationDateKey,
        .contentTypeKey
    ]
    
    private let url: URL
    @State private var impl = ObserverImpl()
    
    var wrappedValue: [URL] {
        impl.files
    }
    
    init(url: URL) {
        self.url = url
    }
    
    func update() {
        impl.start(url: url)
    }
}


extension DirectoryQuery {
    @Observable
    fileprivate final class ObserverImpl {
        private(set) var files: [URL] = []
        
        private var url: URL?
        @ObservationIgnored private var fileDescriptor: Int32?
        @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
        
        func start(url: URL) {
            guard url != self.url else {
                return
            }
            stop()
            switch open(url.path(percentEncoded: false), O_EVTONLY) {
            case -1:
                // failed
                return
            case let fileDescriptor:
                self.fileDescriptor = fileDescriptor
                self.url = url
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .all)
                source.setEventHandler { [weak self] in
                    self?.updateFiles()
                }
                source.setCancelHandler { [weak self] in
                    self?.stop()
                }
                self.source = source
                source.resume()
                updateFiles()
            }
        }
        
        func stop() {
            url = nil
            source.take()?.cancel()
            _ = fileDescriptor.take().map(close)
            updateFiles()
        }
        
        private func updateFiles() {
            guard let url else {
                files = []
                return
            }
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(DirectoryQuery.resourceValueKeys)
                )
            } catch {
                files = []
            }
        }
        
        deinit {
            stop()
        }
    }
}
