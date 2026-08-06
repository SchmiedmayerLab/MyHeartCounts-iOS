//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import Synchronization
import Testing


private final class BackgroundTaskCallbackRecorder: Sendable {
    struct State {
        var completions: [Bool] = []
        var rescheduleCount = 0
    }

    private let storage = Mutex(State())

    var state: State {
        storage.withLock { $0 }
    }

    func recordCompletion(_ success: Bool) {
        storage.withLock { $0.completions.append(success) }
    }

    func recordReschedule() {
        storage.withLock { $0.rescheduleCount += 1 }
    }
}


@Suite
struct MHCBackgroundTasksTests {
    @Test
    func relativeTriggerDateRollsForwardFromEachSubmission() throws {
        let triggerDate = MHCBackgroundTasks.TaskDefinition.NextTriggerDate.after(6 * 60 * 60)
        let firstSubmission = Date(timeIntervalSinceReferenceDate: 1_000)
        let secondSubmission = firstSubmission.addingTimeInterval(12 * 60 * 60)

        let firstTrigger = try #require(triggerDate.resolve(relativeTo: firstSubmission))
        let secondTrigger = try #require(triggerDate.resolve(relativeTo: secondSubmission))

        #expect(firstTrigger == firstSubmission.addingTimeInterval(6 * 60 * 60))
        #expect(secondTrigger == secondSubmission.addingTimeInterval(6 * 60 * 60))
    }

    @Test
    func cancellationReschedulesAndReportsFailureExactlyOnce() async {
        let recorder = BackgroundTaskCallbackRecorder()
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let execution = Task {
            await MHCBackgroundTasks.execute(
                handler: {
                    startedContinuation.yield()
                    startedContinuation.finish()
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch is CancellationError {}
                },
                completion: { recorder.recordCompletion($0) },
                reschedule: { recorder.recordReschedule() }
            )
        }

        for await _ in started {
            break
        }
        execution.cancel()
        await execution.value

        let state = recorder.state
        #expect(state.completions == [false])
        #expect(state.rescheduleCount == 1)
    }
}
