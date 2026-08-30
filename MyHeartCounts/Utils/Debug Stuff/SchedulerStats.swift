//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
@_spi(TestingSupport)
import GroveScheduler
import SwiftUI


struct SchedulerStats: View {
    @Environment(Scheduler.self)
    private var scheduler
    
    @State private var allTasks: [Task]? // swiftlint:disable:this discouraged_optional_collection
    @State private var numOutcomes: Int?
    
    var body: some View {
        Form {
            Section {
                LabeledContent("# tasks" as String, value: allTasks?.count.formatted(.number) ?? "n/a")
                LabeledContent("# outcomes" as String, value: numOutcomes?.formatted(.number) ?? "n/a")
            }
            Section("# task versions" as String) {
                let tasksById = (allTasks ?? []).grouped(by: \.id)
                ForEach(tasksById.keys.sorted(), id: \.self) { id in
                    let tasks = tasksById[id] ?? []
                    LabeledContent(id, value: tasks.count, format: .number)
                }
            }
        }
        .onAppear {
            updateStats()
        }
        .refreshable {
            updateStats()
        }
    }
    
    
    private func updateStats() {
        allTasks = (try? scheduler.queryAllTasks()) ?? []
        numOutcomes = (try? scheduler.queryAllOutcomes())?.count
    }
}
