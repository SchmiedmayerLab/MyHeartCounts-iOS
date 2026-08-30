//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if canImport(SFSafeSymbols) && canImport(GroveStudyDefinition)

public import GroveStudyDefinition
public import SFSafeSymbols


extension TimedWalkingTestConfiguration.Kind {
    /// A SFSymbol suitable for the test
    @inlinable public var symbol: SFSymbol {
        switch self {
        case .walking: .figureWalk
        case .running: .figureRun
        }
    }
}

#endif
