//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import SpeziAccount
import SwiftUI


@Observable
@MainActor
final class DemographicsData {
    @ObservationIgnored private var initialDetails: AccountDetails
    @ObservationIgnored private var account: Account?
    @ObservationIgnored private var updateTask: Task<Void, any Error>?
    @ObservationIgnored private var shouldHandleUpdates = true
    private(set) var updateCounter: UInt64 = 0
    
    var dateOfBirth = Field<Date>(isEmpty: { Calendar.current.isDateInToday($0) }) {
        didSet {
            onChange()
        }
    }
    
    var genderIdentity = Field<GenderIdentity>() {
        didSet {
            defer {
                onChange()
            }
            guard let newGender = self[\.genderIdentity], self[\.sexAtBirth] == nil else {
                return
            }
            switch newGender {
            case .male, .transFemale:
                self[\.sexAtBirth] = .male
            case .female, .transMale:
                self[\.sexAtBirth] = .female
            case .other, .preferNotToState:
                break
            }
        }
    }
    var sexAtBirth = Field<BiologicalSex>() {
        didSet {
            defer {
                onChange()
            }
            guard let newSex = self[\.sexAtBirth], self[\.genderIdentity] == nil else {
                return
            }
            switch newSex {
            case .male:
                self[\.genderIdentity] = .male
            case .female:
                self[\.genderIdentity] = .female
            case .preferNotToState, .intersex:
                break
            }
        }
    }
    var height = Field<HKQuantity>() {
        didSet { onChange() }
    }
    var weight = Field<HKQuantity>() {
        didSet { onChange() }
    }
    var raceEthnicity = Field<RaceEthnicity>(isEmpty: { $0.isEmpty }) {
        didSet { onChange() }
    }
    var latinoStatus = Field<LatinoStatusOption>(isEmpty: { $0 == .notSet }) {
        didSet { onChange() }
    }
    var bloodType = Field<HKBloodType>() {
        didSet { onChange() }
    }
    var comorbidities = Field<Comorbidities>() {
        didSet { onChange() }
    }
    var usRegion = Field<USRegion>() {
        didSet { onChange() }
    }
    var ukRegion = Field<UKRegion>() {
        didSet { onChange() }
    }
    var usEducationLevel = Field<EducationStatusUS>() {
        didSet { onChange() }
    }
    var ukEducationLevel = Field<EducationStatusUK>() {
        didSet { onChange() }
    }
    var usHouseholdIncome = Field<HouseholdIncomeUS>() {
        didSet { onChange() }
    }
    var ukHouseholdIncome = Field<HouseholdIncomeUK>() {
        didSet { onChange() }
    }
    var nhsNumber = Field<NHSNumber>() {
        didSet { onChange() }
    }
    var futureStudiesOptIn = Field<Bool>() {
        didSet { onChange() }
    }
    var stageOfChange = Field<StageOfChangeOption>() {
        didSet { onChange() }
    }
    var referralSource = Field<ReferralSource>() {
        didSet { onChange() }
    }
    
    
    init() {
        initialDetails = AccountDetails()
    }
    
    func populate(from account: Account) {
        self.account = account
        populate(from: account.details ?? AccountDetails())
    }
    
    private func populate(from details: AccountDetails) {
        shouldHandleUpdates = false
        defer {
            shouldHandleUpdates = true
        }
        initialDetails = details
        self[\.dateOfBirth] = details.dateOfBirth
        self[\.genderIdentity] = details.mhcGenderIdentity
        self[\.sexAtBirth] = details.biologicalSexAtBirth
        self[\.height] = details.heightInCM.map { HKQuantity(unit: .meterUnit(with: .centi), doubleValue: $0) }
        self[\.weight] = details.weightInKG.map { HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: $0) }
        self[\.raceEthnicity] = details.raceEthnicity
        self[\.latinoStatus] = details.latinoStatus
        self[\.bloodType] = details.bloodType
        self[\.comorbidities] = details.comorbidities
        self[\.usRegion] = details.usRegion
        self[\.ukRegion] = details.ukRegion
        self[\.usEducationLevel] = details.educationUS
        self[\.ukEducationLevel] = details.educationUK
        self[\.usHouseholdIncome] = details.householdIncomeUS
        self[\.ukHouseholdIncome] = details.householdIncomeUK
        self[\.nhsNumber] = details.nhsNumber
        self[\.futureStudiesOptIn] = details.futureStudies
        self[\.stageOfChange] = details.stageOfChange
        self[\.referralSource] = details.referralSource
    }
    
    fileprivate func onChange() {
        updateCounter &+= 1
        guard shouldHandleUpdates, let account else {
            return
        }
        updateTask?.cancel()
        updateTask = Task {
            try await Task.sleep(for: .seconds(2))
            try await write(to: account)
        }
    }
    
    func write(to account: Account) async throws { // swiftlint:disable:this function_body_length
        var updated = AccountDetails()
        var removed = AccountDetails()
        func write<T: Equatable>(_ newValue: T?, to detailsKeyPath: WritableKeyPath<AccountDetails, T?>) {
            let oldValue = initialDetails[keyPath: detailsKeyPath]
            switch (oldValue, newValue) {
            case (.none, .none):
                break
            case (.some(let oldValue), .none):
                removed[keyPath: detailsKeyPath] = oldValue
            case let (.some(oldValue), .some(newValue)):
                if oldValue != newValue {
                    fallthrough
                }
            case (_, .some(let newValue)):
                updated[keyPath: detailsKeyPath] = newValue
            }
        }
        func write<T: Equatable>(
            _ selfKeyPath: KeyPath<DemographicsData, Field<T>>,
            to detailsKeyPath: WritableKeyPath<AccountDetails, T?>
        ) {
            write(self[selfKeyPath], to: detailsKeyPath)
        }
        func write<T, U: Equatable>(
            _ selfKeyPath: KeyPath<DemographicsData, Field<T>>,
            to detailsKeyPath: WritableKeyPath<AccountDetails, U?>,
            transform: (T) -> U
        ) {
            write(self[selfKeyPath].map(transform), to: detailsKeyPath)
        }
        write(\.dateOfBirth, to: \.dateOfBirth)
        write(\.genderIdentity, to: \.mhcGenderIdentity)
        write(\.sexAtBirth, to: \.biologicalSexAtBirth)
        write(\.height, to: \.heightInCM) {
            $0.doubleValue(for: .meterUnit(with: .centi))
        }
        write(\.weight, to: \.weightInKG) {
            $0.doubleValue(for: .gramUnit(with: .kilo))
        }
        write(\.raceEthnicity, to: \.raceEthnicity)
        write(\.latinoStatus, to: \.latinoStatus)
        write(\.bloodType, to: \.bloodType)
        write(\.comorbidities, to: \.comorbidities)
        write(\.usRegion, to: \.usRegion)
        write(\.ukRegion, to: \.ukRegion)
        write(\.usEducationLevel, to: \.educationUS)
        write(\.ukEducationLevel, to: \.educationUK)
        write(\.usHouseholdIncome, to: \.householdIncomeUS)
        write(\.ukHouseholdIncome, to: \.householdIncomeUK)
        write(\.nhsNumber, to: \.nhsNumber)
        write(\.futureStudiesOptIn, to: \.futureStudies)
        write(\.stageOfChange, to: \.stageOfChange)
        write(\.referralSource, to: \.referralSource)
        let modifications = try AccountModifications(modifiedDetails: updated, removedAccountDetails: removed)
        try await account.accountService.updateAccountDetails(modifications)
    }
}


extension DemographicsData {
    func isEmpty<Value>(_ keyPath: KeyPath<DemographicsData, Field<Value>>) -> Bool {
        self[keyPath: keyPath].isEmpty
    }
    
    /// Accesses the value of a field
    subscript<Value>(_ keyPath: KeyPath<DemographicsData, Field<Value>>) -> Value? {
        self[keyPath: keyPath].value
    }
    
    /// Accesses the value of a field
    subscript<Value>(_ keyPath: ReferenceWritableKeyPath<DemographicsData, Field<Value>>) -> Value? {
        get {
            self[keyPath: keyPath].value
        }
        set {
            self[keyPath: keyPath].value = newValue
        }
    }
}


extension DemographicsData {
    // It's important that this be a struct, since we need these values to be Observation-trackable.
    struct Field<Value> {
        private let _isEmpty: (Value) -> Bool
        fileprivate(set) var value: Value?
        
        var isEmpty: Bool {
            value.map(_isEmpty) ?? true
        }
        
        /// Creates a new `Field` for a demographics value.
        ///
        /// - parameter isEmpty: A closure that determines whether a non-`nil` value for this field should be considered an empty value.
        ///     `nil` values are always considered empty. By default, all non-`nil` values are considered as representing non-empty values.
        fileprivate init(isEmpty: @escaping (Value) -> Bool = { _ in false }) {
            // ^ fileprivate bc we need the properties in the DemographicsData to be mutable,
            // but we don't want external code (outside this file) to be able to assign whole new values.
            self._isEmpty = isEmpty
        }
    }
}


extension DemographicsData {
//    /// NOTE: must annotate with @ObservationIgnored; the property wrapper will correctly handle observability on its own.
//    @MainActor
//    @propertyWrapper
//    struct Field2<Value> {
//        private let _isEmpty: (Value) -> Bool
//        fileprivate(set) var value: Value?
//        
//        var isEmpty: Bool {
//            value.map(_isEmpty) ?? true
//        }
//        
//        /*fileprivate*/ init() {
//            self.init(isEmpty: { _ in false })
//        }
//        
//        /// Creates a new `Field` for a demographics value.
//        ///
//        /// - parameter isEmpty: A closure that determines whether a non-`nil` value for this field should be considered an empty value.
//        ///     `nil` values are always considered empty. By default, all non-`nil` values are considered as representing non-empty values.
//        /*fileprivate*/ init(isEmpty: @escaping (Value) -> Bool) { // somehow make this fileprivate?!
//            self._isEmpty = isEmpty
//        }
//        
//        static subscript(
//            _enclosingInstance instance: DemographicsData,
//            wrapped wrappedKeyPath: ReferenceWritableKeyPath<DemographicsData, Value?>,
//            storage storageKeyPath: ReferenceWritableKeyPath<DemographicsData, Self>
//        ) -> Value? {
//            get {
//                instance.access(keyPath: wrappedKeyPath)
//                return instance[keyPath: storageKeyPath].value
//            }
//            set {
//                let oldValue = instance[keyPath: storageKeyPath].value
//                if let oldValue = oldValue as? any Equatable, let newValue = newValue as? any Equatable, !oldValue.isEqual(newValue) {
//                    // value didn't actually change
//                    return
//                } else {
//                    // value did change (or we can't determine that it didn't)
//                    instance.withMutation(keyPath: wrappedKeyPath) {
//                        instance[keyPath: storageKeyPath].value = newValue
//                        instance.onChange()
//                    }
//                }
//            }
//        }
//        
//        @available(*, unavailable)
//        var wrappedValue: Value? {
//            get {
//                fatalError("Not available")
//            }
//            set {
//                fatalError("Not available")
//            }
//        }
//        
//        var projectedValue: Self {
//            self
//        }
//    }
}
