//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import BackgroundTasks
import Foundation
import GroveFoundation
import SwiftUI


extension MHCBackgroundTasks {
    struct Event: Hashable, Codable {
        enum Kind: String, Hashable, Codable {
            case start
            case stop
            case expiration
        }
        
        let date: Date
        let taskId: MHCBackgroundTasks.TaskIdentifier
        let kind: Kind
    }
    
    static func track(_ kind: Event.Kind, for taskId: TaskIdentifier) {
        LocalPreferencesStore.standard[.backgroundTaskEvents].append(.init(date: .now, taskId: taskId, kind: kind))
    }
}


extension LocalPreferenceKeys {
    static let backgroundTaskEvents = LocalPreferenceKey<[MHCBackgroundTasks.Event]>("backgroundTaskEvents", default: [])
}


extension MHCBackgroundTasks {
    struct EventsView: View {
        private struct ProcessedEvent: Hashable {
            enum StopReason: String, Hashable { // swiftlint:disable:this nesting
                case terminated
                case expired
            }
            let start: Date
            var end: Date?
            let taskId: MHCBackgroundTasks.TaskIdentifier
            var stopReason: StopReason?
        }
        
        @LocalPreference(.backgroundTaskEvents)
        private var events
        
        @State private var pendingRequests: [BGTaskRequest] = []
        
        var body: some View {
            Form {
                Section("Pending Tasks" as String) {
                    ForEach(pendingRequests, id: \.self) { request in
                        VStack(alignment: .leading) {
                            Text(request.earliestBeginDate?.ISO8601Format() ?? "no begin date")
                                .font(.footnote)
                            Text(request.identifier)
                                .font(.footnote.monospaced())
                        }
                    }
                }
                Section("Event Log" as String) {
                    ForEach(processedEvents, id: \.self) { (event: ProcessedEvent) in
                        VStack(alignment: .leading) {
                            Text(event.taskId.rawValue)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(event.start, format: .dateTime)
                                Spacer()
                                if let stopReason = event.stopReason, let end = event.end {
                                    let duration = end.timeIntervalSince(event.start)
                                    Text(
                                        "\(stopReason.rawValue.localizedCapitalized) after \(duration.formatted(.number.precision(.fractionLength(2)))) sec" as String
                                    )
                                } else {
                                    Text("Ongoing" as String)
                                }
                            }
                            .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Background Tasks" as String)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                reloadScheduledTasks()
            }
            .refreshable {
                reloadScheduledTasks()
            }
        }
        
        private var processedEvents: [ProcessedEvent] {
            let events = events.sorted(using: KeyPathComparator(\.date))
            var processed: [ProcessedEvent] = []
            for event in events {
                switch event.kind {
                case .start:
                    processed.append(ProcessedEvent(start: event.date, end: nil, taskId: event.taskId, stopReason: nil))
                case .stop, .expiration:
                    if let idx = processed.lastIndex(where: { $0.taskId == event.taskId }), processed[idx].stopReason == nil {
                        processed[idx].end = event.date
                        processed[idx].stopReason = event.kind == .stop ? .terminated : .expired
                    }
                }
            }
            return processed.sorted(using: KeyPathComparator(\.start, order: .reverse))
        }
        
        private func reloadScheduledTasks() {
            Task { @MainActor in
                pendingRequests = await BGTaskScheduler.shared.pendingTaskRequests()
            }
        }
    }
}
