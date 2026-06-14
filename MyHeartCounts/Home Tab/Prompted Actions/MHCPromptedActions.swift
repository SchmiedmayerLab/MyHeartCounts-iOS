//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
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


extension PromptedAction.ID {
    fileprivate static let sensorKit = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableSensorKit")
    fileprivate static let clinicalRecords = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableClinicalRecords")
    fileprivate static let verifyAccountEmail = Self("edu.stanford.MyHeartCounts.HomeTabAction.verifyAccountEmail")
    fileprivate static let completeDemographics = Self("edu.stanford.MyHeartCounts.HomeTabAction.completeDemographics")
}


extension PromptedAction {
    static let allActions: [PromptedAction] = [
        .completeDemographics, .enableClinicalRecords, .enableSensorKit, .verifyAccountEmail
    ]
    
    private static let enableSensorKit = PromptedAction(
        id: .sensorKit,
        enabledWhen: [
            .daysSinceEnrollment(0...21),
            .custom { _ in
                SensorKit.isAvailable && SensorKit.mhcSensors.contains { $0.authorizationStatus == .notDetermined }
            }
        ],
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
        enabledWhen: [
            .daysSinceEnrollment(0...21),
            .custom { spezi in
                guard HKHealthStore().supportsHealthRecords() else {
                    return false
                }
                return if HealthRecordPermissions.includeInOnboarding {
                    // if the onboarding already asked for health records authorization, we only want to prompt
                    // this again if the user cancelled (rather than rejected) the authorization prompt.
                    spezi.module(ClinicalRecordPermissions.self)?.authorizationState == .cancelled
                } else {
                    // if the Health Records access is not part of the onboarding, we want to prompt it as part of the app itself.
                    // in this case we prompt it if the user hasn't yet been prompted.
                    spezi.module(ClinicalRecordPermissions.self)?.authorizationState == .undetermined
                }
            }
        ],
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
        enabledWhen: [
            .custom { spezi in
                guard let details = spezi.module(Account.self)?.details else {
                    // if there is no user, there is nothing to verify
                    return false
                }
                return !details.isVerified
            }
        ],
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
        enabledWhen: [
            .custom { spezi in
                // TODO verify that this correctly will get re-evaluated when the Account module is loaded after the fact?! (ObservationTracking-wise...)
                guard let account = spezi.module(Account.self),
                      let studyManager = spezi.module(StudyManager.self) else {
                    return false
                }
                let data = DemographicsData()
                data.populate(from: account)
                let layout = demographicsLayout(
                    region: studyManager.preferredLocale.region ?? .unitedStates,
                    didOptInToTrial: account.details?.didOptInToTrial == true
                )
                return layout.completionState(in: data).isIncomplete
            }
        ],
        content: .init(
            symbol: .personTextRectangle,
            title: "Complete Demographics",
            message: "TODO", // TODO
            performActionButtonTitle: "Complete"
        ),
        sheetContent: { onCompletion in
            NavigationStack {
                DemographicsForm()
            }
            .onDisappear {
                // TODO test that this only gets triggered when the view actually disappears as in getting dismissed, but NOT when we simply push smth else onto the nacigationStack!
                onCompletion(.success(()))
            }
        }
    )
    
    
    private static let sheetTest = PromptedAction(
        id: .init("sheetTest"),
        enabledWhen: [],
        content: .init(
            symbol: .textPage,
            title: "Title",
            message: "Message",
            performActionButtonTitle: "Present Sheet"
        )
    ) { onCompletion in
        Form {
            Button("Yes" as String) {
                onCompletion(.success(()))
            }
            Button("No" as String) {
                onCompletion(.failure(NSError(mhcErrorCode: .unspecified, localizedDescription: "oh no")))
            }
        }
    }
}
