//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Algorithms
import SFSafeSymbols
import SwiftUI


struct AchievementsView: View {
    @Environment(AchievementsManager.self)
    private var manager
    
    private var achievementsByCategory: [Achievement.Category: [Achievement]] {
        manager.achievements.grouped(by: \.category)
    }
    
    var body: some View {
        Form {
            // we intentionally do this (instead of eg simply achievements.mapIntoSet)
            // bc we want to append unknown categories in the order in which they appear.
            let allCategories = manager.achievements.reduce(into: Achievement.Category.all) { allCategories, achievement in
                if !allCategories.contains(achievement.category) {
                    allCategories.append(achievement.category)
                }
            }
            ForEach(allCategories) { category in
                if let achievements = achievementsByCategory[category], !achievements.isEmpty {
                    Section(category.title) {
                        ForEach(achievements) { (achievement: Achievement) in
                            switch achievement.visibility {
                            case .always, .secret:
                                AchievementRow(achievement: achievement)
                            case .internal:
                                EmptyView()
                            case .secretUnlessNext:
                                // check if this is the first locked one in the category
                                if shouldDisplay(achievement) {
                                    AchievementRow(achievement: achievement)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Achievements")
    }
    
    /// Whether a `.secretUnlessNext` achievement should be shown: once unlocked, or while it's the next
    /// locked level of its ladder. Unlike the "what's next" rail, this only collapses `.secretUnlessNext`
    /// ladders — `.always` ladders show every level here.
    private func shouldDisplay(_ achievement: Achievement) -> Bool {
        manager.didUnlock(achievement) || manager.isNextLockedLevel(achievement)
    }
}


private struct AchievementRow: View {
    @Environment(AchievementsManager.self)
    private var manager
    
    let achievement: Achievement
    
    var body: some View {
        HStack {
            AchievementIcon(achievement: achievement)
            VStack(alignment: .leading) {
                Text(achievement.title)
                    .font(.body)
                Text(achievement.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let progress = manager.unlockProgress(of: achievement)
            if progress > 0 && progress < 1 {
                Badge("\(progress, format: .percent.precision(.fractionLength(0)))")
                    .tint(.green)
            }
        }
    }
}
