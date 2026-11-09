//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
@testable import MyHeartCounts
import Testing


@Suite
struct MHCBackgroundTasksEventLogTests {
    private let directory = URL.temporaryDirectory.appending(component: UUID().uuidString, directoryHint: .isDirectory)
    
    private func makeEvent(at timeInterval: TimeInterval, kind: MHCBackgroundTasks.Event.Kind = .start) -> MHCBackgroundTasks.Event {
        .init(date: Date(timeIntervalSinceReferenceDate: timeInterval), taskId: .init("task"), kind: kind)
    }
    
    @Test
    func eventsRoundTrip() throws {
        let log = MHCBackgroundTasks.EventLog(directory: directory)
        let events = [makeEvent(at: 1_000.5), makeEvent(at: 1_001.25, kind: .failed(error: "line 1\nline 2"))]
        try log.append(events)
        #expect(log.events() == events)
    }
    
    @Test
    func exceedingTheLimitDropsTheOldestEvents() throws {
        // four lines fit into the limit, and two lines into the half of it that gets kept
        let log = MHCBackgroundTasks.EventLog(directory: directory, maximumFileSize: 300)
        let events = (0..<5).map { makeEvent(at: TimeInterval($0)) }
        for event in events.dropLast() {
            try log.append([event])
        }
        #expect(log.events() == Array(events[0...3]))
        try log.append([events[4]])
        #expect(log.events() == Array(events[3...4]))
    }
    
    @Test
    func oversizedAppendGetsTrimmedRightAway() throws {
        let log = MHCBackgroundTasks.EventLog(directory: directory, maximumFileSize: 300)
        let events = (0..<5).map { makeEvent(at: TimeInterval($0)) }
        try log.append(events)
        #expect(log.events() == Array(events[3...4]))
    }
    
    @Test
    func legacyEventsAreImportedOnce() throws {
        let suiteName = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let prefs = LocalPreferencesStore(defaults: defaults)
        let events = [makeEvent(at: 1_000), makeEvent(at: 1_001, kind: .succeeded)]
        prefs[.backgroundTaskEvents] = events
        
        let log = MHCBackgroundTasks.EventLog(directory: directory)
        try log.importLegacyEvents(from: prefs)
        try log.importLegacyEvents(from: prefs)
        
        #expect(log.events() == events)
        #expect(prefs[.backgroundTaskEvents].isEmpty)
    }
}
