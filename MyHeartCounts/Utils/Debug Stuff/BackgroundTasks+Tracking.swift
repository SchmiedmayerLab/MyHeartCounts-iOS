//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import BackgroundTasks
import Foundation
import SpeziFoundation
import SwiftUI


extension LocalPreferenceKeys {
    static let backgroundTaskEvents = LocalPreferenceKey<[MHCBackgroundTasks.Event]>("backgroundTaskEvents", default: [])
    
    static let backgroundTaskNotifications = LocalPreferenceKey<Bool>("backgroundTaskNotifications", default: false)
}


extension MHCBackgroundTasks {
    struct EventsView: View {
        private struct ProcessedEvent: Hashable {
            enum StopReason: Hashable, CustomStringConvertible { // swiftlint:disable:this nesting
                case succeeded
                case failed(String)
                case expired
                
                var description: String {
                    switch self {
                    case .succeeded:
                        "succeeded"
                    case .expired:
                        "expired"
                    case .failed(let reason):
                        "failed: \(reason)"
                    }
                }
            }
            let start: Date
            var end: Date?
            let taskId: MHCBackgroundTasks.TaskIdentifier
            var stopReason: StopReason?
        }
        
        @LocalPreference(.backgroundTaskNotifications)
        private var enableNotifications
        
        @LocalPreference(.backgroundTaskEvents)
        private var events
        
        @State private var pendingRequests: [BGTaskRequest] = []
        
        var body: some View {
            Form {
                Section {
                    Toggle("Enable Notifications" as String, isOn: $enableNotifications)
                }
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
                                        "\(stopReason.description.localizedCapitalized) after \(duration.formatted(.number.precision(.fractionLength(2)))) sec" as String
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
                case .expiration, .succeeded, .failed:
                    if let idx = processed.lastIndex(where: { $0.taskId == event.taskId }), processed[idx].stopReason == nil {
                        processed[idx].end = event.date
                        processed[idx].stopReason = switch event.kind {
                        case .expiration: .expired
                        case .succeeded: .succeeded
                        case .failed(let error): .failed(error)
                        case .start: .expired // unreachable to doesnt matter
                        }
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
