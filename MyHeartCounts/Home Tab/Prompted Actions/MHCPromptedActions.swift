//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import MyHeartCountsShared
import SFSafeSymbols
@_spi(APISupport)
import Spezi
import SpeziAccount
import SpeziHealthKit
import SpeziSensorKit
import SpeziStudy
import SwiftUI


extension PromptedAction {
    static let allActions: [PromptedAction] = [
        .completeDemographics, .enableClinicalRecords, .enableSensorKit, .verifyAccountEmail
    ]
    
    private static let enableSensorKit = PromptedAction(
        id: .sensorKit,
        state: { context in
            guard context.daysSinceActivation <= 21 else {
                return .unavailable
            }
            guard SensorKit.isAvailable else {
                return .unavailable
            }
            let sensorAuthStates = SensorKit.mhcSensors.mapIntoSet(\.authorizationStatus)
            return sensorAuthStates.contains(.notDetermined) ? .pending : .completed
        },
        content: .init(
            symbol: .waveformPathEcgRectangle,
            title: "Enable SensorKit",
            message: "ENABLE_SENSORKIT_SUBTITLE",
            performActionButtonTitle: "Enable"
        )
    ) { spezi in
        guard let sensorKit = spezi.module(SensorKit.self) else {
            return
        }
        let result = try await sensorKit.requestAccess(to: SensorKit.mhcSensors)
        for sensor in result.authorized {
            try? await sensor.startRecording()
        }
    }
    
    
    private static let enableClinicalRecords = PromptedAction(
        id: .clinicalRecords,
        state: { context in
            guard context.daysSinceActivation <= 21 else {
                return .unavailable
            }
            guard HKHealthStore().supportsHealthRecords() else {
                return .unavailable
            }
            guard let module = context.spezi.module(ClinicalRecordPermissions.self) else {
                return .unavailable
            }
            let authState = module.authorizationState
            return if HealthRecordPermissions.includeInOnboarding {
                // if the onboarding already asked for health records authorization, we only want to prompt
                // this again if the user cancelled (rather than rejected) the authorization prompt.
                switch authState {
                case .cancelled, .undetermined:
                    .pending
                case .decided:
                    // NOTE that completed here does not mean that the user actually gave us access;
                    // it just means that the user completed the task of responding to the clinical records request.
                    .completed
                }
            } else {
                // if the Health Records access is not part of the onboarding, we want to prompt it as part of the app itself.
                // in this case we prompt it if the user hasn't yet been prompted.
                switch authState {
                case .undetermined:
                    .pending
                case .cancelled, .decided:
                    // NOTE that completed here does not mean that the user actually gave us access;
                    // it just means that the user completed the task of responding to the clinical records request.
                    .completed
                }
            }
        },
        content: .init(
            symbol: HealthRecordPermissions.symbol,
            title: "Enable Clinical Records",
            message: "HEALTH_RECORDS_NUDGE_SUBTITLE",
            performActionButtonTitle: "Enable"
        )
    ) { spezi in
        try await spezi.module(ClinicalRecordPermissions.self)?.askForAuthorization(askAgainIfCancelledPreviously: true)
    }
    
    
    private static let verifyAccountEmail = PromptedAction(
        id: .verifyAccountEmail,
        state: { context in
            guard let details = context.spezi.module(Account.self)?.details else {
                // if there is no user, there is nothing to verify
                return .unavailable
            }
            return details.isVerified ? .completed : .pending
        },
        content: .init(
            symbol: .envelope,
            title: "Verify Account Email",
            message: "Check your inbox and click the confirmation link to verify your account.",
            performActionButtonTitle: "Open Mail App"
        )
    ) { _ in
        await UIApplication.shared.open("message://")
    }
    
    
    private static let completeDemographics = PromptedAction(
        id: .completeDemographics,
        state: { context in
            let spezi = context.spezi
            guard let account = spezi.module(Account.self),
                  let studyManager = spezi.module(StudyManager.self),
                  let details = account.details,
                  !details.isIncomplete else {
                return .unavailable
            }
            let data = DemographicsData()
            data.populate(from: account)
            let layout = demographicsLayout(
                region: studyManager.preferredLocale.region ?? .unitedStates,
                didOptInToTrial: details.didOptInToTrial == true
            )
            return layout.completionState(in: data).isIncomplete ? .pending : .completed
        },
        content: .init(
            symbol: .personTextRectangle,
            title: "Complete Demographics",
            message: "PROMPTED_ACTION_COMPLETE_DEMOGRAPHICS_MESSAGE",
            performActionButtonTitle: "Complete"
        ),
        sheetContent: {
            NavigationStack {
                DemographicsForm()
            }
        }
    )
}
