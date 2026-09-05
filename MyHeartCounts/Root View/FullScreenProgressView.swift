//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SwiftUI


struct FullScreenProgressView: View {
    private let title: Text
    private let subtitle: Text?
    
    var body: some View {
        ProgressView {
            VStack(alignment: .center) {
                title
                if let subtitle {
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(.background)
    }
    
    init(title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
    }
    
    @_disfavoredOverload
    init(title: some StringProtocol, subtitle: (some StringProtocol)? = String?.none) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
    }
}
