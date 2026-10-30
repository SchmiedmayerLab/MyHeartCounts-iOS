//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import Observation


extension Module where Self: Sendable {
    func onChange<Value: Equatable & Sendable>(
        of keyPath: any KeyPath<Self, Value> & Sendable,
        initial: Bool = false,
        handler: @escaping @Sendable (_ oldValue: Value, _ newValue: Value) -> Void
    ) {
        let oldValue = self[keyPath: keyPath]
        if initial {
            handler(oldValue, oldValue)
        }
        withObservationTracking {
            _ = self[keyPath: keyPath]
        } onChange: { [weak self] in
            RunLoop.current.perform { [weak self] in
                guard let self else {
                    return
                }
                let newValue = self[keyPath: keyPath]
                if newValue != oldValue {
                    handler(oldValue, newValue)
                }
                self.onChange(of: keyPath, handler: handler)
            }
        }
    }
}
