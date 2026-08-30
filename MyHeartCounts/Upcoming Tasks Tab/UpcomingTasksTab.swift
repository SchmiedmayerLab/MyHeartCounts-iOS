//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFoundation
import GroveScheduler
import GroveSchedulerUI
import GroveStudyDefinition
import GroveViews
import SFSafeSymbols
import SwiftUI


struct UpcomingTasksTab: RootViewTab {
    static var tabTitle: LocalizedStringResource { "Tasks" }
    static var tabSymbol: SFSymbol { .calendar }
    
    var body: some View {
        NavigationStack {
            Form {
                TasksList(
                    mode: .upcoming(includeIndefinitePastTasks: false, showFallbackTasks: true),
                    timeRange: .weeks(2),
                    headerConfig: .timeRange(subtitle: .hide),
                    eventGroupingConfig: .byDay,
                    noTasksMessageLabels: .init(title: "No Upcoming Tasks")
                )
            }
            .navigationTitle(String(localized: Self.tabTitle))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AlwaysAvailableTaskActionsMenu()
                }
                accountToolbarItem
            }
        }
        // we need this here, to prevent any Task-related sheets from getting dismissed when you close and re-open the app (don't ask me why...)
        .taskPerformingAnchor()
    }
}


extension UpcomingTasksTab {
    @ViewBuilder
    static func sectionHeader(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil
    ) -> some View {
        let title = title.localizedString()
        let subtitle = subtitle?.localizedString()
        if !title.isEmpty || !(subtitle ?? "").isEmpty {
            Section {
                VStack(alignment: .leading) {
                    Text(title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                            .fontDesign(.rounded)
                    }
                }
                .foregroundStyle(.secondary)
                .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .font(.title2)
                .fontDesign(.rounded)
                .fontWeight(.bold)
            }
            .listSectionSpacing(.compact)
        }
    }
}
