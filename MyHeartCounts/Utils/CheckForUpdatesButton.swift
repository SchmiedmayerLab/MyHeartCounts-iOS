//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import StoreKit
import SwiftUI


struct CheckForUpdateButton<Label: View>: View {
    @Environment(\.openURL)
    private var openUrl
    private let label: Label
    
    @State private var url: URL = Self.url(for: .production)
    
    var body: some View {
        Link2(url) {
            label
        }
        .link2Style(.iosSafari)
        .task {
            guard let environment = try? await AppTransaction.shared else {
                return
            }
            switch environment {
            case .verified(let transaction):
                url = Self.url(for: transaction.environment)
            case .unverified(let transaction, _):
                url = Self.url(for: transaction.environment)
            }
        }
    }
    
    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }
    
    private static func url(for environment: AppStore.Environment) -> URL {
        switch environment {
        case .sandbox:
            "https://beta.itunes.apple.com/v1/app/\(MyHeartCounts.appId)"
        default:
            "https://apps.apple.com/app/id\(MyHeartCounts.appId)"
        }
    }
}
