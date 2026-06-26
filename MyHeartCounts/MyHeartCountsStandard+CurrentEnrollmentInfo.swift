//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SpeziFoundation
import SpeziStudy


extension MyHeartCountsStandard {
    struct CurrentEnrollmentInfo: Sendable {
        let studyId: String
        let studyRevision: UInt
    }
    
    private static let lock = RWLock()
    nonisolated(unsafe) private static var _currentEnrollmentInfo: CurrentEnrollmentInfo?
    
    static var currentEnrollmentInfo: CurrentEnrollmentInfo? {
        lock.withReadLock {
            _currentEnrollmentInfo
        }
    }
    
    
    @MainActor
    static func _updateCurrentEnrollmentInfo(_ studyManager: StudyManager) { // swiftlint:disable:this identifier_name
        lock.withWriteLock {
            guard let enrollment = studyManager.studyEnrollments.first else {
                _currentEnrollmentInfo = nil
                return
            }
            _currentEnrollmentInfo = .init(
                studyId: enrollment.studyId.uuidString,
                studyRevision: enrollment.studyRevision
            )
        }
    }
}
