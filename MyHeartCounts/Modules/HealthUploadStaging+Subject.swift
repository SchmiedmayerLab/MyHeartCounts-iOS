//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if DEBUG
import class ModelsR4.Reference


extension HealthUploadStaging {
    /// Stages against a fixed subject, standing in for the signed-in account a test has no way to
    /// supply. Compiled out of release builds, so a shipping app always attributes to the account.
    nonisolated static func forTesting(
        persistence: Persistence,
        autoElideUploadsWhenInsertingDeletions: Bool = true,
        subject: Reference
    ) -> HealthUploadStaging {
        let staging = Self(
            persistence: persistence,
            autoElideUploadsWhenInsertingDeletions: autoElideUploadsWhenInsertingDeletions
        )
        staging.testingSubject = subject
        return staging
    }
}
#endif
