//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveFoundation
import GroveStudy
import GroveViews
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
            if !Grove.didLoadFirebase {
                // load the firebase modules into Grove, and give it a couple seconds to fully configure everything
                // the crux here is that there isn't a mechanism by which Firebase would let us know when it
                Grove.loadFirebase(for: region)
                try? await Task.sleep(for: .seconds(3))
            }
            do {
                try await studyLoader.update()
            } catch {
                path.append(customView: UnableToLoadStudyDefinitionStep())
                return
            }
            path.nextStep()
        } else {
            for result in results {
                switch result {
                // 2 bc we want everything else to have passed
                case .ineligible(.regionNotYetSupportedButComingSoon(let region)) where results.count == 2:
                    path.append {
                        RegionComingSoon(selectedRegion: region, availabilityStatus: .comingSoon)
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
}


#Preview {
    ManagedNavigationStack {
        EligibilityScreening()
    }
    .environment(StudyBundleLoader.shared)
    .environment(OnboardingDataCollection())
}
