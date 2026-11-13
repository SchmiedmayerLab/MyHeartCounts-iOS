//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseStorage
import Grove


/// Directs the uploads of ``ManagedFileUpload`` into the bucket for collected health data.
final class DataCollectionStorage: Module {
    @Dependency(ManagedFileUpload.self)
    private var managedFileUpload

    private let bucket: String
    private let emulatorConfig: (host: String, port: Int)?

    init(bucket: String, emulatorConfig: (host: String, port: Int)? = nil) {
        self.bucket = bucket
        self.emulatorConfig = emulatorConfig
    }

    @MainActor
    func configure() {
        if let emulatorConfig {
            Storage.storage(url: "gs://\(bucket)").useEmulator(withHost: emulatorConfig.host, port: emulatorConfig.port)
        }
        managedFileUpload.storageBucket = bucket
    }
}
