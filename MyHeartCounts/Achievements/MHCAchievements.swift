//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// IDEA ideally we'd also have some of these achievements, when displayed in the UI, be buttons that directly take the user to where they can perform the action that would give them the acheivement, or maybe even directly initiates the thing?!

import Foundation
import SFSafeSymbols
import SpeziFoundation


extension Achievement.Category {
    static let all: [Self] = [
        .studyParticipation, .appUsage, .health
    ]
    
    static let appUsage = Self(id: "app-usage", title: "General")
    static let studyParticipation = Self(id: "study-participation", title: "Study Participation")
    static let health = Self(id: "health", title: "Health")
}


extension Achievement.Subcategory {
    static let enrollmentDuration = Self(id: "enrollment-duration", formsLadder: true)
    static let stepCount = Self(id: "step-count", formsLadder: true)
}


extension Achievement.Trigger {
    static let completeEnrollment = Self(
        id: "complete-enrollment",
        recordingMode: .recordOnce
    )
    
    static let completeQuestionnaire = Self(
        id: "complete-questionnaire",
        recordingMode: .keepAll
    )
    static let complete6MinWalkTest = Self(
        id: "complete-6mwt",
        recordingMode: .keepAll
    )
    static let complete12MinRunTest = Self(
        id: "complete-12mrt",
        recordingMode: .keepAll
    )
}


extension Achievement.Metric {
    static let enrollmentDurationInDays = Self(
        id: "enrollment-duration-days",
        rule: .atLeast(base: 0)
    )
    static let enrollmentDurationInWeeks = Self(
        id: "enrollment-duration-weeks",
        rule: .atLeast(base: 0)
    )
    static let enrollmentDurationInMonths = Self(
        id: "enrollment-duration-months",
        rule: .atLeast(base: 0)
    )
    static let enrollmentDurationInYears = Self(
        id: "enrollment-duration-years",
        rule: .atLeast(base: 0)
    )
    
    static let dailyStepCount = Self(
        id: "step-count-daily",
        rule: .atLeast(base: 0)
    )
}


extension Achievement {
    private struct EnrollmentDurationAchievementInput {
        let metric: Metric
        let component: Calendar.Component
        let count: Int
        let symbol: SFSymbol
        
        init(_ metric: Metric, _ component: Calendar.Component, _ count: Int, _ symbol: SFSymbol) {
            self.metric = metric
            self.component = component
            self.count = count
            self.symbol = symbol
        }
    }
    
    private static let durationFmt: DateComponentsFormatter = {
        let fmt = DateComponentsFormatter()
        fmt.unitsStyle = .full
        fmt.allowedUnits = [.weekOfMonth, .month, .year]
        return fmt
    }()
    
    static func registerDefaultAchievements(with manager: AchievementsManager) { // swiftlint:disable:this function_body_length
        manager.register(achievements: Array { // swiftlint:disable:this closure_body_length
            Self(
                id: "first-questionnaire",
                category: .appUsage,
                subcategory: nil,
                kind: .eventOnce(trigger: .completeQuestionnaire),
                title: "Questionnaire Extraordinaire",
                description: "Complete your first questionnaire",
                symbol: .textPage,
                visibility: .always
            )
            Self(
                id: "first-6mwt",
                category: .appUsage,
                subcategory: nil,
                kind: .eventOnce(trigger: .completeQuestionnaire),
                title: "Pedestrian Pioneer",
                description: "Record your first Walk Test",
                symbol: .figureWalk,
                visibility: .always
            )
            Self(
                id: "first-12mrt",
                category: .appUsage,
                subcategory: nil,
                kind: .eventOnce(trigger: .completeQuestionnaire),
                title: "Cooper Trooper",
                description: "Record your first Run Test",
                symbol: .figureRun,
                visibility: .always
            )
            Self(
                id: "first-ecg",
                category: .appUsage,
                subcategory: nil,
                kind: .eventOnce(trigger: .completeQuestionnaire),
                title: "Cardio Connoisseur",
                description: "Record your first ECG",
                symbol: .waveformPathEcgRectangle,
                visibility: .always
            )
            
            for (count, title): (Int, LocalizedStringResource) in [
                (10, "I'm walking here!"),
                (15, "Super Streaker"),
                (20, "Mega Streaker"),
                (30, "Giga Streaker"),
                (40, "Uber Streaker"),
                (50, "The Humble Walker")
            ] {
                Self(
                    id: "step-count-daily-\(count)k",
                    category: .health,
                    subcategory: .stepCount,
                    kind: .threshold(metric: .dailyStepCount, target: Double(count * 1000)),
                    title: title,
                    description: "Walk \((count * 1000).formatted(.number)) steps in a day",
                    symbol: .figureWalk,
                    visibility: .secretUnlessNextInLadder
                )
            }
            
            Achievement(
                id: "initial-enrollment",
                category: .studyParticipation,
                subcategory: nil, // standalone one-off, not a level of the .enrollmentDuration progression
                kind: .eventOnce(trigger: .completeEnrollment),
                title: "Welcome to the fold",
                description: "Enroll into the study",
                symbol: .partyPopper,
                visibility: .always
            )
            
            // participation streaks
            for (idx, input) in enrollmentDurationAchievementInputs.enumerated() {
                if let durationText = Self.durationFmt.string(from: DateComponents(component: input.component, value: input.count)) {
                    Achievement(
                        id: "participation-streak-\(input.count)-\(input.component)",
                        category: .studyParticipation,
                        subcategory: .enrollmentDuration,
                        kind: .threshold(metric: input.metric, target: Double(input.count)),
                        title: Self.anniversaryNames[idx],
                        description: "Cross \(durationText) of study enrollment",
                        symbol: input.symbol,
                        visibility: .secretUnlessNextInLadder
                    )
                }
            }
        })
    }
}


extension Achievement {
    /// source: https://en.wikipedia.org/wiki/Wedding_anniversary#Traditional_anniversary_gifts
    private static let anniversaryNames: [LocalizedStringResource] = [
        "Paper Anniversary",
        "Cotton Anniversary",
        "Leather Anniversary",
        "Flower Anniversary",
        "Wood Anniversary",
        "Iron Anniversary",
        "Copper Anniversary",
        "Bronze Anniversary",
        "Pottery Anniversary",
        "Tin Anniversary",
        "Steel Anniversary",
        "Silk Anniversary",
        "Lace Anniversary",
        "Ivory Anniversary",
        "Crystal Anniversary",
        "Porcelain Anniversary",
        "Silver Anniversary",
        "Pearl Anniversary",
        "Coral Anniversary",
        "Ruby Anniversary",
        "Sapphire Anniversary",
        "Gold Anniversary",
        "Emerald Anniversary",
        "Diamond Anniversary"
    ]
    
    private static let enrollmentDurationAchievementInputs: [EnrollmentDurationAchievementInput] = [
        .init(.enrollmentDurationInWeeks, .weekOfYear, 1, .calendar),
        .init(.enrollmentDurationInMonths, .month, 1, .calendar),
        .init(.enrollmentDurationInMonths, .month, 3, .calendar),
        .init(.enrollmentDurationInMonths, .month, 6, .calendar),
        .init(.enrollmentDurationInYears, .year, 1, .calendar),
        .init(.enrollmentDurationInYears, .year, 2, .calendar),
        .init(.enrollmentDurationInYears, .year, 3, .calendar),
        .init(.enrollmentDurationInYears, .year, 4, .calendar),
        .init(.enrollmentDurationInYears, .year, 5, .calendar)
    ]
}


extension DateComponents {
    fileprivate init(component: Calendar.Component, value: Int) {
        self.init()
        setValue(value, for: component)
    }
}
