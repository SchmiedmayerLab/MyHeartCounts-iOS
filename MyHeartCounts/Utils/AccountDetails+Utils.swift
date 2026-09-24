//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveAccount


extension AccountDetails {
    /// Updates the `AccountDetails` by applying the modifications.
    mutating func apply(_ modifications: AccountModifications) {
        add(contentsOf: modifications.modifiedDetails, merge: true)
        removeAll(modifications.removedAccountKeys)
    }
}
