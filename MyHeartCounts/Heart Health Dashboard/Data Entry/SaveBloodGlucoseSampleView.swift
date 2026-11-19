//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveViews
import SwiftUI


/// Lets the participant pick which kind of blood glucose measurement they want to enter, and then enter it.
///
/// The dashboard has a single Blood Glucose tile, which covers two different measurements:
/// individual blood glucose readings (stored in HealthKit), and HbA1c, a lab value reflecting the average blood glucose of the past months.
struct SaveBloodGlucoseSampleView: View {
    private enum Kind: CaseIterable, Identifiable {
        case reading
        case hbA1c

        var id: Self {
            self
        }

        var sampleType: MHCQuantitySampleType {
            switch self {
            case .reading: .healthKit(.bloodGlucose)
            case .hbA1c: .custom(.hbA1c)
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .reading: "Blood Glucose Reading"
            case .hbA1c: "HbA1c"
            }
        }

        var subtitle: LocalizedStringResource {
            switch self {
            case .reading: "A single measurement, for example from a finger-prick test or a lab test."
            case .hbA1c: "Your average blood glucose over the past 2–3 months, from a lab test."
            }
        }
    }

    @State private var kind: Kind?

    var body: some View {
        if let kind {
            // replacing the chooser (instead of pushing onto it) lets the entry sheet's dismiss close the whole sheet.
            SaveQuantitySampleView(sampleType: kind.sampleType)
        } else {
            chooser
        }
    }

    private var chooser: some View {
        Form {
            Section {
                ForEach(Kind.allCases) { kind in
                    Button {
                        self.kind = kind
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .foregroundStyle(.primary)
                            Text(kind.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("BloodGlucoseKind:\(kind.sampleType.id)")
                }
            } header: {
                Text("What would you like to enter?")
            }
        }
        .navigationTitle("Enter Blood Glucose")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DismissButton()
            }
        }
    }
}
