//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import MyHeartCountsShared
import OSLog


extension SetupTestEnvironment {
    private static let logger = Logger(category: .init("SetupTestEnvironment.EarlyReset"))
    
    /// Deletes as much of the locally persisted app state as possible.
    ///
    /// This function exists to aid development and testing, and should never be used in regular releases.
    /// Its purpose is to get the app as close to a fresh install state as possible, like it had been fully deleted
    /// and reinstalled prior to launching.
    ///
    /// - Important: This **must** be called from ``MyHeartCounts/init()``, i.e. before the app delegate's
    ///     `willFinishLaunchingWithOptions` runs.
    ///     (i.e. before any Grove modules have been initialized and configured.)
    ///
    /// The underlying issue here is that several modules will perform initial setup operations based on their persisted state,
    /// which will end up running concurrently with the `SetupTestEnvironment` module's `configure()` function.
    /// (For example, the `StudyManager` will try to set up its enrollment upon launch (if one exists within the SwiftData database),
    /// which includes setting up the HealthKit background observers and requesting HealthKit access, which in turn will mess up
    /// the app's state as expected by the UI tests.)
    /// We want to avoid any modules performing such on-launch stuff, as it will mess up the reset operation.
    /// So what we do instead is that we simply delete the entire Documents folder immediately upon launch
    /// (hence also why this needs to be called directly from ``MyHeartCounts/init()``), to ensure that
    /// no modules will have any data to operate on.
    ///
    /// This deliberately talks to the file system directly rather than going through the modules that own the
    /// respective files: at this point none of them exist yet, and that is the whole point.
    /// Plus also, we want to allow the modules to freely move their stuff around should they feel like it.
    ///
    /// - Note: The keychain is intentionally left alone, matching what deleting the app would do: iOS does not
    ///     remove an app's keychain items on uninstall. Firebase therefore still restores the previous session
    ///     here, and is signed out properly via `accountService.logout()` in ``resetExistingData()``.
    ///
    /// This function never throws. A failure to delete one item is logged and the remaining items are still
    /// attempted -- a partially-failed reset must not prevent the app from launching.
    static func performEarlyResetIfNeeded() {
        guard LaunchOptions.launchOptions[.setupTestEnvironment].resetExistingData else {
            return
        }
        logger.notice("Performing early reset of all locally persisted state")
        deleteAllContainerContents()
        // We clear `UserDefaults` in two passes.
        // The first drops the app's entire persistent domain, i.e. also the keys written directly by third-party
        // SDKs (FirebaseCore's data-collection flag, FirebaseMessaging's token state, ...), which a
        // delete-and-reinstall would have taken along with the container.
        // The second re-clears our own keys via `removeObject(forKey:)`: `removePersistentDomain(forName:)`
        // targeting the app's own bundle id makes no promise about invalidating `UserDefaults.standard`'s
        // in-process cache, and `MyHeartCounts.init()` writes preferences immediately after this returns.
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        LocalPreferencesStore.standard.removeAllEntries(in: .app)
    }

    /// Unconditionally deletes all contents of the app's data container, except UserDefaults.
    ///
    /// - Note: We delete the *contents* of the top-level directories rather than the directories themselves,
    ///     so that anything assuming their existence keeps working.
    private static func deleteAllContainerContents() {
        let fileManager = FileManager.default
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        for directory in ["Documents", "Library", "tmp"] {
            let url = home.appending(path: directory, directoryHint: .isDirectory)
            let contents = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for child in contents where child.lastPathComponent != "Preferences" {
                // ^ `Library/Preferences` backs `UserDefaults`, which the caller clears via its own API instead
                //   of by deleting the plist: cfprefsd has the file open and caches its contents in memory, so
                //   deleting it here is unreliable -- the cached values can simply get written back out again.
                remove(at: child)
            }
        }
    }

    private static func remove(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.debug("Removed \(url.lastPathComponent)")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // nothing to delete; the common case for the -wal/-shm sidecars.
        } catch {
            logger.error("Unable to remove \(url.lastPathComponent): \(error)")
        }
    }

    // NOTE: we deliberately do NOT touch Firebase's keychain items here, even though the session they hold is
    // what lets `FirebaseAccountService.configure()` restore the previous user before `resetExistingData()` gets
    // a chance to run. Deleting them out-of-band would pair a wiped keychain with Firebase state we are not
    // clearing (its `UserDefaults` entries, which we leave alone above), i.e. it trades a transient stale session
    // for a persistently inconsistent Firebase. Signing out through the SDK -- `accountService.logout()` in
    // `resetExistingData()` -- is the only way to take both sides down together.
}
