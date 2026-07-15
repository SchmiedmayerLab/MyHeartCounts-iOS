//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKit
import SpeziViews
import SwiftUI


struct HealthDashboardTile<Content: View, Accessory: View>: View {
    private static var insets: EdgeInsets {
        EdgeInsets(horizontal: 9, vertical: 5)
    }
    
    @Environment(\.isRecentValuesViewInDetailedStatsSheet)
    private var isRecentValuesViewInDetailedStatsSheet
    
    private let title: Text
    private let subtitle: Text?
    private let headerInsets: EdgeInsets
    private let accessory: Accessory
    private let content: Content
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        title
                            .font(.headline)
                        if let subtitle {
                            subtitle
                                .font(.subheadline)
                        }
                    }
                    Spacer()
                    accessory
                }
                .padding(headerInsets)
                .padding(EdgeInsets(top: Self.insets.top, leading: 0, bottom: Self.insets.top, trailing: 0))
                .frame(height: 57)
                Divider()
            }
            Spacer()
            content
            Spacer()
        }
        .if(!isRecentValuesViewInDetailedStatsSheet) {
            $0
                .padding(EdgeInsets(top: 0, leading: Self.insets.leading, bottom: Self.insets.bottom, trailing: Self.insets.trailing))
                .background(.dashboardTile)
        }
        .frame(minHeight: 129)
    }
    
    init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        headerInsets: EdgeInsets = .zero,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.headerInsets = headerInsets
        self.subtitle = subtitle.map(Text.init)
        self.accessory = accessory()
        self.content = content()
    }
    
    @_disfavoredOverload
    init(
        title: some StringProtocol,
        subtitle: (some StringProtocol & SendableMetatype)? = String?.none,
        headerInsets: EdgeInsets = .zero,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.headerInsets = headerInsets
        self.subtitle = subtitle.map(Text.init)
        self.accessory = accessory()
        self.content = content()
    }
}
