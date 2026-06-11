//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import SFSafeSymbols
@_spi(APISupport)
import Spezi
import SpeziHealthKit
import SpeziSensorKit


extension HomeTab.PromptedAction.ID {
    static let sensorKit = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableSensorKit")
    static let clinicalRecords = Self("edu.stanford.MyHeartCounts.HomeTabAction.EnableClinicalRecords")
}


extension HomeTab.PromptedAction {
    static let allActions: [HomeTab.PromptedAction] = [.enableSensorKit, .enableClinicalRecords]
    
    static let enableSensorKit = HomeTab.PromptedAction(
        id: .sensorKit,
        conditions: [
            .daysSinceEnrollment(0...21),
            .custom { _ in
                SensorKit.isAvailable && SensorKit.mhcSensors.contains { $0.authorizationStatus == .notDetermined }
            }
        ],
        content: .init(
            symbol: .waveformPathEcgRectangle,
            title: "Enable SensorKit",
            message: "ENABLE_SENSORKIT_SUBTITLE"
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
    
    static let enableClinicalRecords = HomeTab.PromptedAction(
        id: .clinicalRecords,
        conditions: [
            .daysSinceEnrollment(0...21),
            .custom { spezi in
                if HealthRecordPermissions.includeInOnboarding {
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
            message: "HEALTH_RECORDS_NUDGE_SUBTITLE"
        )
    ) { spezi in
        try await spezi.module(ClinicalRecordPermissions.self)?.askForAuthorization(askAgainIfCancelledPreviously: true)
    }
}
