//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API

public import struct GroveFoundation.Version


extension Version {
    /// The version succeeding this version's major component, i.e. `(major+1).0.0`.
    ///
    /// - Note: Any pre-release identifiers or build metadata are discarded.
    @inlinable public var nextMajor: Version {
        Version(major + 1, 0, 0)
    }
    
    /// The version succeeding this version's minor component, i.e. `major.(minor+1).0`.
    ///
    /// - Note: Any pre-release identifiers or build metadata are discarded.
    @inlinable public var nextMinor: Version {
        Version(major, minor + 1, 0)
    }
    
    /// The version succeeding this version's patch component, i.e. `major.minor.(patch+1)`.
    ///
    /// - Note: Any pre-release identifiers or build metadata are discarded.
    @inlinable public var nextPatch: Version {
        Version(major, minor, patch + 1)
    }
}
