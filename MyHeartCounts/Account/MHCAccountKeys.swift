//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable discouraged_optional_boolean

@preconcurrency import FirebaseStorage
import Foundation
import SpeziAccount
import SpeziFoundation
import SpeziLocalStorage
import SwiftUI


// MARK: Study & Enrollment

extension AccountDetails {
    @AccountKey(
        id: "hasWithdrawnFromStudy",
        name: "Has withdrawn from Study",
        category: .other,
        options: .mutable,
        as: Bool.self
    )
    var hasWithdrawnFromStudy: Bool?
    
    /// The date the user first enrolled in the study.
    @AccountKey(
        id: "dateOfEnrollment",
        name: "Date of Enrollment",
        category: .other,
        options: .mutable,
        as: Date.self,
        initial: .empty(.distantPast)
    )
    var dateOfEnrollment: Date?
    
    // NOTE: this is, for the time being, stored using SpeziLocalStorage.
//    /// The date the current study actication, i.e. when the user logged in to the app and started/resumed their study participation.
//    @AccountKey(
//        id: "currentStudyActivationDate",
//        name: "Date of Enrollment",
//        category: .other,
//        options: .mutable,
//        as: Date.self,
//        initial: .empty(.distantPast)
//    )
//    var currentStudyActivationDate: Date?
    
    @AccountKey(
        id: "lastSignedConsentVersion",
        name: "Consent Version",
        as: String.self
    )
    var lastSignedConsentVersion: String?
    
    @AccountKey(
        id: "lastSignedConsentDate",
        name: "Consent Date",
        category: .other,
        options: .mutable,
        as: Date.self,
        initial: .empty(Date(timeIntervalSince1970: 0))
    )
    var lastSignedConsentDate: Date?
    
    @AccountKey(
        id: "didOptInToTrial",
        name: "Did Opt In to Trial",
        category: .other,
        options: .mutable,
        as: Bool.self
    )
    var didOptInToTrial: Bool?
    
    
    @AccountKey(
        id: "preferredWorkoutTypes",
        name: "Preferred Workout Types",
        category: .other,
        options: .mutable,
        as: WorkoutPreferenceSetting.WorkoutTypes.self,
        initial: .default(.init())
    )
    var preferredWorkoutTypes: WorkoutPreferenceSetting.WorkoutTypes?
    
    @AccountKey(
        id: "preferredNotificationTime",
        name: "Preferred Notification Time",
        category: .other,
        options: .mutable,
        as: WorkoutPreferenceSetting.NotificationTime.self,
        initial: .empty(.init(hour: 0))
    )
    var preferredNudgeNotificationTime: WorkoutPreferenceSetting.NotificationTime?
    
    @AccountKey(
        id: "lastActiveDate",
        name: "Last Active Date",
        category: .other,
        options: .mutable,
        as: Date.self,
        initial: .empty(.distantPast)
    )
    var lastActiveDate: Date?
}


// MARK: App-Specific Stuff

extension AccountDetails {
    @AccountKey(
        id: "fcmToken",
        name: "FCM Token",
        as: String.self
    )
    var fcmToken: String?
    
    @AccountKey(id: "enableAppDebugMode", name: "Enable App Debug Mode", as: Bool.self)
    var enableDebugMode: Bool?
    
    @AccountKey(id: "timeZone", name: "Time Zone", as: String.self)
    var timeZone: String?

    @AccountKey(id: "language", name: "Language", as: String.self)
    var language: String?
    
    @AccountKey(id: "preferredMeasurementSystem", name: "Preferred Measurement System", as: String.self)
    var preferredMeasurementSystem: String?
    
    @AccountKey(id: "extendedActivityNudgesOptIn", name: "Post-Trial Nudges Opt-In", as: Bool.self)
    var postTrialNudgesOptIn: Bool?
    
    @AccountKey(
        id: "mostRecentOnboardingStep",
        name: "",
        category: .other,
        options: .mutable,
        as: OnboardingStep.self,
        initial: .default(.init(rawValue: ""))
    )
    var mostRecentOnboardingStep: OnboardingStep?
}


@KeyEntry(
    \.hasWithdrawnFromStudy,
    \.dateOfEnrollment, \.lastSignedConsentVersion, \.lastSignedConsentDate, \.didOptInToTrial,
    \.fcmToken, \.enableDebugMode, \.timeZone, \.language, \.preferredMeasurementSystem, \.lastActiveDate,
    \.mostRecentOnboardingStep, \.preferredWorkoutTypes, \.preferredNudgeNotificationTime, \.postTrialNudgesOptIn
)
extension AccountKeys {}


// MARK: Other

extension LocalPreferenceKeys {
    static let studyActivationDate = LocalPreferenceKey<Date?>("studyActivationDate")
}
