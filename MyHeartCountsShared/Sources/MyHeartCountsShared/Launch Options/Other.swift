//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2023 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

public import struct SpeziFoundation.Version


extension LaunchOptions {
    /// Whether we should force-enable the debug mode, even if the account key is set to `false`.
    ///
    /// - Note: Specifying `false` for this option when the account key is `true` will not force-disable the debug mode.
    public static let forceEnableDebugMode = LaunchOption<Bool>("--forceEnableDebugMode", default: false)
    
    /// Whether the app should enable its HealthKit Clinical Records integration
    public static let enableHealthRecords = LaunchOption<Bool>("--enableHealthRecords", default: true)
    
    /// Whether the "please sign the new consent version" sheet should be presented to the user if they've never signed the consent before.
    ///
    /// Defaults to true; the option exists to allow the UI tests (which typically use temporary users that don't have a signed consent) to suppress the sheet.
    public static let triggerConsentRenewalIfNeverSigned = LaunchOption<Bool>("--triggerConsentRenewalIfNeverSigned", default: true)
}


extension LaunchOptions {
    /// Whether the app should supply demographics values for temporary accounts created via the ``setupTestEnvironment`` option.
    public static let supplyDemographicsWhenCreatingTestAccount = LaunchOption<Bool>("--supplyDemographicsWhenCreatingTestAccount", default: true)
    // swiftlint:disable:previous identifier_name
}


extension LaunchOptions {
    /// Force-overrides the last-signed consent version, if the app is being launched with ``setupTestEnvironment`` present.
    ///
    /// Intended solely for UI testing purposes.
    public static let overrideLastSignedConsentVersion = LaunchOption<Version?>("--overrideLastSignedConsentVersion", default: nil)
}


extension LaunchOptions {
    /// Forces the app to use the new questionnaire UI from SpeziQuestionnaire, instead of using the legacy ResearchKit-based UI.
    public static let useNewQuestionnaireUI = LaunchOption<Bool>("--useNewQuestionnaireUI", default: false)
    
    /// Manual data entry in the dashboard should use questionnaires instead of the dedicated quantity sample entry forms.
    public static let dashboardDataEntryUsesQuestionnaires = LaunchOption<Bool>("--dashboardDataEntryUsesQuestionnaires", default: false)
}

#endif
