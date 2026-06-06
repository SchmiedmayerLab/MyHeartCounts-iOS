//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import SFSafeSymbols
import SwiftUI


struct AchievementIcon: View {
    @Environment(AchievementsManager.self)
    private var manager
    
    let achievement: Achievement
    
    var body: some View {
        let state = manager.state(of: achievement)
        CircularProgressView(state.progress, lineWidth: 3) {
            let symbol: SFSymbol? = switch state {
            case .unlocked:
                achievement.symbol
            case .locked:
                achievement.visibility == .secret ? nil : achievement.symbol
            }
            if let symbol {
                Image(systemSymbol: symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .tint(.green)
        .frame(width: 40, height: 40)
    }
}
