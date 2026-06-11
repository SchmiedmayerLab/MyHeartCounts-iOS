//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable discouraged_optional_boolean

import Foundation
import SpeziConsent
import SpeziFoundation


@Observable
@MainActor
final class OnboardingDataCollection: Sendable {
    struct Screening: Sendable {
        enum DateOfBirthResponse: Sendable {
            case date(Date)
            case binaryAtLeast(minAge: Int, response: Bool)
        }
        
        var dateOfBirth: DateOfBirthResponse?
        var region: Locale.Region?
        var speaksEnglish: Bool?
        var sharedAppleID: Bool?
        // periphery:ignore
        var physicalActivity: Bool?
    }
    
    struct Comprehension: Sendable {
        /// Comprehension Question: "If at any point during this study I do not feel well, I should immediately contact my healthcare provider"
        var seekHelpIfNotFeelingWell: Bool?
        /// Comprehension Question: "I am not required to complete all or any parts of this study if I don’t want to"
        var studyParticipationIsVoluntary: Bool?
        /// Comprehension Question: "Once I start participating in this study, I can choose to not continue at any time with no repercussions to me"
        var canStopParticipatingAtAnyTime: Bool?
    }
    
    var screening = Screening()
    var comprehension = Comprehension()
    var consentResponses: ConsentDocument.UserResponses?
}


extension OnboardingDataCollection {
    enum OptInState {
        case unknown
        case optedIn
        case notOptedIn
    }
    
    var trialOptInState: OptInState {
        switch consentResponses?.selectedOption(for: .trialOptIn) {
        case .trialYes: .optedIn
        case .trialNo: .notOptedIn
        default: .unknown
        }
    }
}
