//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


struct ElectrocardiogramStatsSample: Hashable, Sendable {
    let id: String
    let date: Date
    let endDate: Date
}
