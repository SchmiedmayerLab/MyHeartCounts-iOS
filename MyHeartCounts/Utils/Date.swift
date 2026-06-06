//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseCore
import Foundation


//extension Date {
//    init(
//}


extension Date {
    typealias XXX = Date.ComponentsFormatStyle
    
    func test() {
        Date.ComponentsFormatStyle.components(style: .wide, fields: [.day]).format(Date().addingTimeInterval(-100000)..<Date())
    }
}
