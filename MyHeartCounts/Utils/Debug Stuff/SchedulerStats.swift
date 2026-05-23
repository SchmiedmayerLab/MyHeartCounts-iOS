//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Algorithms
import SpeziFoundation
@_spi(TestingSupport)
@testable import SpeziScheduler
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
                let taskVersionsByTask: [Task: Int] = (allTasks ?? []).mapIntoSet(\.firstVersion).reduce(into: [:]) {
                    $0[$1] = $1.firstVersion.allVersions.count { _ in true }
                }
                ForEach(Array(taskVersionsByTask).sorted(using: KeyPathComparator(\.value, order: .reverse)), id: \.key) { task, count in
                    LabeledContent(String(localized: task.title), value: count, format: .number)
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
