//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import MyHeartCounts
import Testing


@Suite
struct CHINumberTests {
    @Test
    func validate() {
        #expect(CHINumber(validating: "0101801238") != nil)
        #expect(CHINumber(validating: "010180 1238") != nil)
        #expect(CHINumber(validating: "010180-1238") != nil)
        // wrong check digit
        #expect(CHINumber(validating: "0101801239") == nil)
        // valid check digit, but the 32nd isn't a valid day of birth
        #expect(CHINumber(validating: "3202801236") == nil)
        // too short
        #expect(CHINumber(validating: "010180123") == nil)
    }
}
