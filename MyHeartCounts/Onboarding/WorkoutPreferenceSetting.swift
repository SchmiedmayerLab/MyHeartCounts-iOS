//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveAccount
import GroveOnboarding
import GroveViews
import OSLog
import SFSafeSymbols
import SwiftUI


/// Lets the user set their preferred workout mode, and a notification time for related notification.
struct WorkoutPreferenceSetting: View {
    // swiftlint:disable attributes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(ManagedNavigationStack.Path.self) private var path: ManagedNavigationStack.Path?
    @Environment(Account.self) private var account: Account? // optional to easily make it work with the Preview
    // swiftlint:enable attributes
    
    @State private var viewState: ViewState = .idle
    @State private var workoutTypes: WorkoutTypes = .init()
    @State private var notificationTime = NotificationTime(hour: 9)
    
    var body: some View {
        Form {
            formSections
            if let path {
                Section {
                    OnboardingActionsView("Continue", viewState: $viewState) {
                        await saveToAccountDetails()
                        path.nextStep()
                    }
                    .listRowInsets(.zero)
                }
            }
        }
        .navigationTitle("Workout Preference")
        .interactiveDismissDisabled()
        .toolbar {
            if path == nil { // we're presented outside of the onboarding, i.e. as a sheet
                ToolbarItem(placement: .confirmationAction) {
                    if #available(iOS 26, *) {
                        AsyncButton(role: .confirm, state: $viewState) {
                            await saveToAccountDetails()
                            dismiss()
                        } label: {
                            Text("Done")
                        }
                    } else {
                        AsyncButton("Done", state: $viewState) {
                            await saveToAccountDetails()
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            if let details = account?.details {
                workoutTypes = details.preferredWorkoutTypes ?? .init()
                notificationTime = details.preferredNudgeNotificationTime ?? .init(hour: 9)
            }
        }
    }
    
    @ViewBuilder private var formSections: some View {
        Section {
            Text("WORKOUT_PREFERENCE_TEXT")
        }
        Section("Preferred Workout Types") {
            ForEach(WorkoutType.options) { option in
                Button {
                    if workoutTypes.contains(option) {
                        workoutTypes.remove(option)
                    } else {
                        workoutTypes.insert(option)
                    }
                } label: {
                    Label {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if workoutTypes.contains(option) {
                                Image(systemSymbol: .checkmark)
                                    .fontWeight(.medium)
                                    .accessibilityLabel("Selection Checkmark")
                            }
                        }
                    } icon: {
                        Image(systemSymbol: option.symbol)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        Section {
            let dateBinding = Binding<Date> {
                calendar.date(
                    bySettingHour: notificationTime.hour,
                    minute: notificationTime.minute,
                    second: 0,
                    of: .now
                ) ?? .now // will never fail, but just to be safe we provide a default
            } set: { newValue in
                let components = calendar.dateComponents([.hour, .minute], from: newValue)
                notificationTime = NotificationTime(
                    hour: components.hour ?? 9,
                    minute: components.minute ?? 0
                )
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("Notification Time")
                    Text("NOTIFICATION_TIME_SUBTITLE")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CustomDatePicker(selection: dateBinding, minuteInterval: 15)
                    .frame(maxWidth: 100)
            }
            .frame(minHeight: 51 + (2 / 3))
        }
    }
    
    
    private func saveToAccountDetails() async {
        guard let account else {
            logger.notice("Unable to store workout preference: no account")
            return
        }
        do {
            var newDetails = AccountDetails()
            newDetails.preferredWorkoutTypes = workoutTypes
            newDetails.preferredNudgeNotificationTime = notificationTime
            let modifications = try AccountModifications(modifiedDetails: newDetails)
            try await account.accountService.updateAccountDetails(modifications)
        } catch {
            logger.error("Error updating workout preference account details: \(error)")
        }
    }
}


extension WorkoutPreferenceSetting {
    private struct CustomDatePicker: UIViewRepresentable {
        typealias UIViewType = UIDatePicker
        
        @Binding private var selection: Date
        private let minuteInterval: Int
        
        init(selection: Binding<Date>, minuteInterval: Int = 1) {
            self._selection = selection
            self.minuteInterval = minuteInterval
        }
        
        func makeUIView(context: Context) -> UIDatePicker {
            let view = UIDatePicker()
            view.datePickerMode = .time
            view.preferredDatePickerStyle = .compact
            view.addAction(UIAction { action in
                guard let view = action.sender as? UIDatePicker else {
                    return
                }
                selection = view.date
            }, for: .valueChanged)
            return view
        }
        
        func updateUIView(_ view: UIDatePicker, context: Context) {
            view.date = selection
            view.locale = context.environment.locale
            view.calendar = context.environment.calendar
            view.minuteInterval = minuteInterval
        }
    }
}


#if DEBUG
#Preview {
    ManagedNavigationStack {
        WorkoutPreferenceSetting()
            .navigationBarTitleDisplayMode(.inline)
        Text("Next View")
    }
}
#endif
