//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@_spi(APISupport)
import Spezi
import SpeziFoundation
import SpeziStudy
import SpeziViews
import SwiftUI


struct EligibilityScreening: View {
    @Environment(StudyBundleLoader.self)
    private var studyLoader

    private let components: [any ScreeningComponent] = [
        AgeAtLeast(style: .toggle, minAge: 18),
        IsFromRegion(
            enabledRegions: [.unitedStates],
            comingSoonRegions: [.unitedKingdom]
        ),
        // We ask if the user speaks the current language.
        // Since MHC only enables localization for languages we officially support (English and Spanish),
        // this will always ask for one of the two, even if the user's phone is set e.g. to German.
        // (Bc it'll fall back to EN or ES...)
        SpeaksLanguage(allowedLanguage: .current),
        IsUsingSharedAppleID()
    ]
    
    
    var body: some View {
        SinglePageScreening(
            title: "ELIGIBILITY_STEP_TITLE",
            subtitle: "ELIGIBILITY_STEP_SUBTITLE"
        ) {
            components
        } didAnswerAllRequestedFields: { data in
            @MainActor
            func nonnil(_ keyPath: KeyPath<OnboardingDataCollection.Screening, (some Any)?>) -> Bool {
                data.screening[keyPath: keyPath] != nil
            }
            return nonnil(\.dateOfBirth) && nonnil(\.region) && nonnil(\.speaksEnglish) && nonnil(\.sharedAppleID)
        } continue: { data, path in
            await process(data: data, path: path)
        }
    }
    
    
    private func process(data: OnboardingDataCollection, path: ManagedNavigationStack.Path) async {
        let results = components.mapIntoSet { $0.evaluate(data) }
        if results == [.eligible] {
            guard let region = data.screening.region else {
                // unreachable
                return
            }
            if await loadStudy(for: region, path: path) {
                path.nextStep()
            }
        } else {
            for result in results {
                switch result {
                // 2 bc we want everything else to have passed
                case .ineligible(.regionNotYetSupportedButComingSoon(let region)) where results.count == 2:
                    path.append {
                        RegionComingSoon(selectedRegion: region, availabilityStatus: .comingSoon) {
                            if await loadStudy(for: .unitedKingdom, path: path) {
                                path.removeLast()
                                path.nextStep()
                            }
                        }
                    }
                    return
                // 2 bc we want everything else to have passed
                case .ineligible(.unsupportedRegion(let region)) where results.count == 2:
                    path.append {
                        RegionComingSoon(selectedRegion: region, availabilityStatus: .notSupported)
                    }
                    return
                default:
                    continue
                }
            }
            path.append {
                NotEligibleView()
            }
        }
    }

    private func loadStudy(for region: Locale.Region, path: ManagedNavigationStack.Path) async -> Bool {
        if !Spezi.didLoadFirebase {
            // Give the dynamically loaded Firebase modules time to finish configuring.
            Spezi.loadFirebase(for: region)
            try? await Task.sleep(for: .seconds(3))
        } else if FeatureFlags.enableUKStudyTesting,
                  FeatureFlags.overrideFirebaseConfig == nil,
                  let previousRegion = DeferredConfigLoading.activeFirebaseConfig?.region,
                  [.unitedStates, .unitedKingdom].contains(previousRegion),
                  let studyManager = SpeziAppDelegate.spezi?.module(StudyManager.self) {
            // Both test variants use the same backend. Keep the study selection in sync when going back in onboarding.
            DeferredConfigLoading.activeFirebaseConfig = .region(region)
            studyManager.preferredLocale = Locale(language: Locale.current.language.withRegion(nil), region: region)
        }
        do {
            try await studyLoader.update()
            return true
        } catch {
            path.append(customView: UnableToLoadStudyDefinitionStep())
            return false
        }
    }
}


#Preview {
    ManagedNavigationStack {
        EligibilityScreening()
    }
    .environment(StudyBundleLoader.shared)
    .environment(OnboardingDataCollection())
}
