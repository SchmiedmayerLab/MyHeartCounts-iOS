//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveStudy
import Synchronization


extension MyHeartCountsStandard {
    struct CurrentEnrollmentInfo: Sendable {
        let studyId: String
        let studyRevision: UInt
    }
    
    private static let _currentEnrollmentInfo = Mutex<CurrentEnrollmentInfo?>(nil)
    
    static var currentEnrollmentInfo: CurrentEnrollmentInfo? {
        _currentEnrollmentInfo.withLock { $0 }
    }
    
    
    @MainActor
    static func _updateCurrentEnrollmentInfo(_ studyManager: StudyManager) { // swiftlint:disable:this identifier_name
        let enrollmentInfo = studyManager.studyEnrollments.first.map { enrollment in
            CurrentEnrollmentInfo(
                studyId: enrollment.studyId.uuidString,
                studyRevision: enrollment.studyRevision
            )
        }
        _currentEnrollmentInfo.withLock { $0 = enrollmentInfo }
    }
}
