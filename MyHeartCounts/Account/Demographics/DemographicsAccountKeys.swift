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


extension AccountKeyCategory {
    static let demographics = Self(title: "Demographics")
}


extension AccountDetails {
    @AccountKey(
        id: "mhcGenderIdentity",
        name: "Gender Identity",
        category: .demographics,
        options: .mutable,
        as: GenderIdentity.self,
        initial: .empty(.preferNotToState)
    )
    var mhcGenderIdentity: GenderIdentity?
    
    
    @AccountKey(id: "usRegion", name: "US State / Region", category: .demographics, options: .mutable, as: USRegion.self, initial: .empty(.notSet))
    var usRegion: USRegion?
    
    @AccountKey(id: "usZipCodePrefix", name: "First 3 Digits of ZIP Code", category: .demographics, options: .mutable, as: String.self)
    var usZipCodePrefix: String?
    
    @AccountKey(
        id: "householdIncomeUS",
        name: "Household Income",
        category: .demographics,
        options: .mutable,
        as: HouseholdIncomeUS.self,
        initial: .empty(.notSet)
    )
    var householdIncomeUS: HouseholdIncomeUS?
    
    
    @AccountKey(
        id: "ukRegion",
        name: "UK Region",
        category: .demographics,
        options: .mutable,
        as: UKRegion.self,
        initial: .empty(.notSet)
    )
    var ukRegion: UKRegion?
    
    @AccountKey(
        id: "householdIncomeUK",
        name: "Household Income",
        category: .demographics,
        options: .mutable,
        as: HouseholdIncomeUK.self,
        initial: .empty(.notSet)
    )
    var householdIncomeUK: HouseholdIncomeUK?
    
    
    @AccountKey(id: "heightInCM", name: "Height", category: .demographics, options: .mutable, as: Double.self)
    var heightInCM: Double?
    
    @AccountKey(id: "weightInKG", name: "Weight", category: .demographics, options: .mutable, as: Double.self)
    var weightInKG: Double?
    
    @AccountKey(id: "raceEthnicity", name: "Race / Ethnicity", category: .demographics, options: .mutable, as: RaceEthnicity.self)
    var raceEthnicity: RaceEthnicity?
    
    @AccountKey(
        id: "latinoStatus",
        name: "Latino / Hispanic?",
        category: .demographics,
        options: .mutable,
        as: LatinoStatusOption.self,
        initial: .empty(.notSet)
    )
    var latinoStatus: LatinoStatusOption?
    
    @AccountKey(
        id: "biologicalSexAtBirth",
        name: "Biological Sex at Birth",
        category: .demographics,
        options: .mutable,
        as: BiologicalSex.self,
        initial: .empty(.preferNotToState)
    )
    var biologicalSexAtBirth: BiologicalSex?
    
    @AccountKey(
        id: "bloodType",
        name: "Blood Type",
        category: .demographics,
        options: .mutable,
        as: HKBloodType.self,
        initial: .empty(.notSet)
    )
    var bloodType: HKBloodType?
    
    @AccountKey(
        id: "educationUS",
        name: "Educational Level",
        category: .demographics,
        options: .mutable,
        as: EducationStatusUS.self,
        initial: .empty(.notSet)
    )
    var educationUS: EducationStatusUS?
    
    @AccountKey(
        id: "educationUK",
        name: "Educational Level",
        category: .demographics,
        options: .mutable,
        as: EducationStatusUK.self,
        initial: .empty(.notSet)
    )
    var educationUK: EducationStatusUK?
    
    @AccountKey(
        id: "comorbidities",
        name: "Comorbidities",
        category: .demographics,
        options: .mutable,
        as: Comorbidities.self,
        initial: .empty(.init())
    )
    var comorbidities: Comorbidities?
    
    @AccountKey(
        id: "nhsNumber",
        name: "NHS Number",
        category: .demographics,
        options: .mutable,
        as: NHSNumber.self,
        initial: .empty(NHSNumber(unchecked: ""))
    )
    var nhsNumber: NHSNumber?
    
    @AccountKey(
        id: "ukPostcode",
        name: "Postcode (UK)",
        category: .demographics,
        options: .mutable,
        as: String.self
    )
    var ukPostcode: String?
    
    @AccountKey(id: "futureStudies", name: "", category: .demographics, options: .mutable, as: Bool.self)
    var futureStudies: Bool? // swiftlint:disable:this discouraged_optional_boolean
    
    @AccountKey(
        id: "stageOfChange",
        name: "Stage of Change",
        category: .demographics,
        options: .mutable,
        as: StageOfChangeOption.self,
        initial: .empty(.notSet)
    )
    var stageOfChange: StageOfChangeOption?
}


@KeyEntry(
    \.usRegion, \.usZipCodePrefix, \.householdIncomeUS, \.educationUS,
    \.ukRegion, \.ukPostcode, \.householdIncomeUK, \.educationUK,
    \.heightInCM, \.weightInKG, \.bloodType, \.nhsNumber, \.mhcGenderIdentity,
    \.raceEthnicity, \.latinoStatus,
    \.biologicalSexAtBirth, \.comorbidities, \.futureStudies, \.stageOfChange
)
extension AccountKeys {}


// MARK: Codable conformances

extension HKBloodType: @retroactive Encodable, @retroactive Decodable, RawRepresentableAccountKey {}
