//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFoundation
import SwiftUI


extension HealthKitStatsCalculator {
    struct DebugControlView: View {
        @Environment(HealthKitStatsCalculator.self)
        private var statsCalc
        
        var body: some View {
            Form {
                Section {
                    Toggle("Is Active" as String, isOn: Binding<Bool> {
                        statsCalc.isActive
                    } set: { newValue in
                        if newValue {
                            statsCalc.start()
                        } else {
                            statsCalc.stop()
                        }
                    })
                    Button("Reset all query anchors" as String) {
                        let clear = {
                            LocalPreferencesStore.standard.removeAllEntries(in: HealthKitStatsCalculator.QueryAnchors.namespace)
                        }
                        if statsCalc.isActive {
                            statsCalc.stop()
                            clear()
                            statsCalc.start()
                        } else {
                            clear()
                        }
                    }
                }
            }
            .navigationTitle("HealthKit Stats Calc" as String)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
