//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation


// MARK: US

struct EducationStatusUS: DemographicsSelectableSimpleValue {
    let id: String
    let displayTitle: LocalizedStringResource
    let displaySubtitle: LocalizedStringResource?
    
    var rawValue: String { id }
    
    init(id: String, title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {
        self.id = id
        self.displayTitle = title
        self.displaySubtitle = subtitle
    }
}

extension EducationStatusUS {
    static let notSet = Self(id: "notSet", title: "Not Set")
    static let preferNotToState: Self? = Self(id: "preferNotToState", title: "Prefer not to state")
    
    static let options: [Self] = [
        Self(id: "didNotAttendSchool", title: "Didn't attend school"),
        Self(id: "gradeSchool", title: "Grade School"),
        Self(id: "highSchool", title: "High School"),
        Self(id: "someCollege", title: "Some College", subtitle: "Some college or vocational school or associate degree"),
        Self(id: "bachelor", title: "Bachelor", subtitle: "College graduate or Baccalaureate Degree"),
        Self(id: "master", title: "Master's Degree"),
        Self(id: "doctoralDegree", title: "Doctoral Degree", subtitle: "Ph.D., M.D., J.D., etc.")
    ]
}


// MARK: UK

struct EducationStatusUK: DemographicsSelectableSimpleValue {
    let id: String
    let displayTitle: LocalizedStringResource
    let displaySubtitle: LocalizedStringResource?
    
    var rawValue: String { id }
    
    init(id: String, title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {
        self.id = id
        self.displayTitle = title
        self.displaySubtitle = subtitle
    }
}

extension EducationStatusUK {
    static let notSet = Self(id: "notSet", title: "Not Set")
    static let preferNotToState: Self? = Self(id: "preferNotToState", title: "Prefer not to state")
    
    static let options: [Self] = [
        Self(id: "highSchool", title: "High school / A levels / GCSE"),
        Self(id: "undergraduate", title: "Undergraduate"),
        Self(id: "master", title: "Postgraduate Master's"),
        Self(id: "doctoralDegree", title: "Postgraduate Doctorate")
    ]
}
