//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import SwiftUI


struct AgeAtLeast: ScreeningComponent {
    enum Style {
        case toggle
        case enterDate
    }
    
    @Environment(\.calendar)
    private var cal
    @Environment(OnboardingDataCollection.self)
    private var data
    
    let title: LocalizedStringResource
    private let labelText: LocalizedStringResource
    private let style: Style
    private let minAge: Int
    
    var body: some View {
        switch style {
        case .toggle:
            // or use the `SingleChoiceScreeningComponentImpl`??
            Toggle(isOn: Binding<Bool> {
                switch data.screening.dateOfBirth {
                case .binaryAtLeast(minAge: _, let response):
                    response
                case nil, .date:
                    false
                }
            } set: { newValue in
                data.screening.dateOfBirth = .binaryAtLeast(minAge: minAge, response: newValue)
            }) {
                Text(labelText)
                    .fontWeight(.medium)
            }
        case .enterDate:
            let binding = Binding<Date> {
                switch data.screening.dateOfBirth {
                case nil, .binaryAtLeast:
                    Date.now
                case .date(let date):
                    date
                }
            } set: { newValue in
                data.screening.dateOfBirth = .date(newValue)
            }
            DatePicker(
                selection: binding,
                in: Date.distantPast...Date.now,
                displayedComponents: .date
            ) {
                Text(labelText)
                    .fontWeight(.medium)
            }
        }
    }
    
    
    init(style: Style, minAge: Int) {
        self.style = style
        self.minAge = minAge
        title = "Age"
        switch style {
        case .toggle:
            labelText = "Are you \(minAge) years old or older?"
        case .enterDate:
            labelText = "Date of Birth"
        }
    }
    
    func evaluate(_ data: OnboardingDataCollection) -> ScreeningResult {
        switch data.screening.dateOfBirth {
        case nil:
            return .ineligible(.other)
        case .date(let date):
            let age = cal.dateComponents([.year], from: date, to: cal.startOfNextDay(for: .now)).year ?? 0
            return age >= minAge ? .eligible : .ineligible(.other)
        case .binaryAtLeast(minAge: _, let response):
            return response ? .eligible : .ineligible(.other)
        }
    }
}
