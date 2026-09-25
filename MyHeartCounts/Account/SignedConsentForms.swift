//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

@preconcurrency import FirebaseStorage
import Foundation
import GroveAccount
import GroveConsent
import GroveFoundation
import GroveViews
import OSLog
import QuickLook
import SFSafeSymbols
import SwiftUI


struct SignedConsentForms: View {
    @Environment(Account.self)
    private var account: Account?
    
    private let storage = Storage.storage()
    @State private var files: [StorageReference] = []
    @State private var fileBeingFetched: StorageReference?
    @State private var presentedFile: URL?
    
    var body: some View {
        Form {
            if account == nil {
                ContentUnavailableView("Not logged in", systemSymbol: .personSlash)
            } else {
                ForEach(files, id: \.self) { file in
                    ConsentFileRow(file: file, fileBeingFetched: $fileBeingFetched, presentedFile: $presentedFile)
                        .disabled(fileBeingFetched != nil && fileBeingFetched != file)
                }
            }
        }
        .navigationTitle("Consent Documents")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($presentedFile)
        .task {
            await update()
        }
        .refreshable {
            Task {
                await update()
            }
        }
        .onChange(of: presentedFile) { old, new in
            if let old, new == nil {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }
    
    private func update() async {
        guard let accountId = account?.details?.accountId else {
            return
        }
        let folder = storage.reference(withPath: "users/\(accountId)/consent/")
        do {
            files = try await folder.listAll().items
            files.sort(using: KeyPathComparator(\.name, order: .reverse)) // filenames are unix timestamps, so this should work
        } catch {
            logger.error("Error fetching all consent files for user: \(error)")
            files = []
        }
    }
}


private struct ConsentFileRow: View {
    let file: StorageReference
    @Binding var fileBeingFetched: StorageReference?
    @Binding var presentedFile: URL?
    
    @State private var viewState: ViewState = .idle
    @State private var storageRefCustomMetadata: [String: String] = [:]
    @State private var formMetadata: MarkdownDocument.Metadata?
    
    var body: some View {
        AsyncButton(state: $viewState) {
            fileBeingFetched = file
            defer {
                fileBeingFetched = nil
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, conformingTo: .pdf)
            _ = try await file.writeAsync(toFile: url)
            presentedFile = url
        } label: {
            buttonLabel
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            do {
                storageRefCustomMetadata = try await file.getMetadata().customMetadata ?? [:]
                formMetadata = try storageRefCustomMetadata["consentFormMetadata"].map {
                    try JSONDecoder().decode(MarkdownDocument.Metadata.self, from: $0)
                }
            } catch {
                logger.error("Error fetching consent file metadata: \(error)")
            }
        }
    }
    
    @ViewBuilder private var buttonLabel: some View {
        HStack {
            VStack(alignment: .leading) {
                if let version = formMetadata?.version {
                    Text(version.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let title = formMetadata?.title {
                    Text(title)
                        .font(.headline)
                }
            }
            Spacer()
            if let date = storageRefCustomMetadata["date"].flatMap({ try? Date($0, strategy: MyHeartCountsStandard.consentDateFormat) }) {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
