//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import SpeziFoundation
import SpeziViews
import SwiftUI


struct IsFromRegion: ScreeningComponent {
    let title: LocalizedStringResource = "Region"
    // swiftlint:disable attributes
    @Environment(\.locale) private var locale
    @Environment(OnboardingDataCollection.self) private var data
    // swiftlint:enable attributes
    
    let enabledRegions: Set<Locale.Region>
    let comingSoonRegions: Set<Locale.Region>
    
    @State private var isPresentingRegionPicker = false
    
    var body: some View {
        @Bindable var data = data
        let allRegions = Locale.Region.isoRegions
            .filter { $0.subRegions.isEmpty }
            .sorted { $0.localizedName(in: locale, includeEmoji: .none) < $1.localizedName(in: locale, includeEmoji: .none) }
        let regionsList: [Locale.Region] = Array {
            if let currentRegion = locale.region {
                currentRegion
                allRegions.filter { $0 != currentRegion }
            } else {
                allRegions
            }
        }
        Button {
            isPresentingRegionPicker = true
        } label: {
            HStack {
                Text("What country do you currently live in?")
                    .fontWeight(.medium)
                    .foregroundStyle(.textLabel)
                Spacer()
                if let region = data.screening.region {
                    Text(region.localizedName(in: locale, includeEmoji: .none))
                        .foregroundStyle(.textLabel.secondary)
                }
                DisclosureIndicator()
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .sheet(isPresented: $isPresentingRegionPicker) {
            ListSelectionSheet("Select a Region", items: regionsList, selection: $data.screening.region) { region in
                region.localizedName(in: locale, includeEmoji: .front)
            }
        }
    }
    
    func evaluate(_ data: OnboardingDataCollection) -> ScreeningResult {
        guard let region = data.screening.region else {
            return .ineligible(.other)
        }
        return if enabledRegions.contains(region) {
            .eligible
        } else if comingSoonRegions.contains(region) {
            .ineligible(.regionNotYetSupportedButComingSoon(region))
        } else {
            .ineligible(.unsupportedRegion(region))
        }
    }
}
