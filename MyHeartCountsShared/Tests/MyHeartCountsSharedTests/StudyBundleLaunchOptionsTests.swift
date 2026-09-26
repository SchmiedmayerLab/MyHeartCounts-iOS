//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

import Foundation
import MHCStudyDefinition
@testable import MyHeartCountsShared
import Testing


@Suite
struct StudyBundleLaunchOptionsTests {
    @Test(arguments: ["firebase", "bundledWithApp"])
    func namedSourceDefaultsToStanford(_ source: String) throws {
        let options = LaunchOptions.commandLineOptionsContainer(for: ["", "--studyBundle", source])
        let expected: StudyBundleSelector = source == "firebase" ? .firebase(.stanford) : .bundledWithApp(.stanford)
        #expect(try options._decode(.studyBundleSelector) == expected)
    }

    @Test(arguments: StudyVariant.allCases)
    func namedSourceRoundTrip(_ variant: StudyVariant) throws {
        for selector in [StudyBundleSelector.firebase(variant), .bundledWithApp(variant)] {
            let args = selector.launchOptionArgs(for: .studyBundleSelector)
            let options = LaunchOptions.commandLineOptionsContainer(for: [""] + args)
            #expect(try options._decode(.studyBundleSelector) == selector)
        }
    }

    @Test(arguments: ["bundle", "relative.studybundle", "./firebase", "/tmp/mhc.studybundle", "/tmp/My Study.studybundle"])
    func localPaths(_ path: String) throws {
        let options = LaunchOptions.commandLineOptionsContainer(for: ["", "--studyBundle", path])
        let selector = try #require(try options._decode(.studyBundleSelector))
        guard case .atUrl(let url) = selector else {
            Issue.record("Expected a local study bundle for \(path)")
            return
        }
        let expected = URL(filePath: path, relativeTo: path.starts(with: "/") ? nil : .documentsDirectory)
        #expect(url.absoluteURL == expected.absoluteURL)
        let encoded = selector.launchOptionArgs(for: .studyBundleSelector)
        let roundTrip = LaunchOptions.commandLineOptionsContainer(for: [""] + encoded)
        #expect(try roundTrip._decode(.studyBundleSelector) == .atUrl(expected.absoluteURL))
    }

    @Test
    func webURLRoundTrip() throws {
        let raw = "https://example.org/mhc.studybundle.tar.zst"
        let selector = StudyBundleSelector.atUrl(try #require(URL(string: raw)))
        let args = selector.launchOptionArgs(for: .studyBundleSelector)
        #expect(args == ["--studyBundle", raw])
        let options = LaunchOptions.commandLineOptionsContainer(for: [""] + args)
        #expect(try options._decode(.studyBundleSelector) == selector)
    }

    @Test(arguments: ["firebase:", "firebase:typo", "firebase:imperial:extra", "bundledWithApp:", "bundledWithApp:typo"])
    func malformedNamedVariantThrows(_ input: String) {
        let options = LaunchOptions.commandLineOptionsContainer(for: ["", "--studyBundle", input])
        #expect(throws: LaunchOptionDecodingError.self) {
            try options._decode(.studyBundleSelector)
        }
    }

    @Test(arguments: StudyVariant.allCases)
    func variantOverrideRoundTrip(_ variant: StudyVariant) throws {
        let args = Optional(variant).launchOptionArgs(for: .studyVariant)
        #expect(args == ["--studyVariant", variant.rawValue])
        let options = LaunchOptions.commandLineOptionsContainer(for: [""] + args)
        #expect(try options._decode(.studyVariant) == .some(variant))
    }

    @Test
    func variantOverrideIsOptional() {
        let options = LaunchOptions.commandLineOptionsContainer(for: [""])
        #expect(options[.studyVariant] == nil)
        #expect(Optional<StudyVariant>.none.launchOptionArgs(for: .studyVariant).isEmpty)
    }

    @Test(arguments: [[], ["unknown"], ["stanford", "imperial"]])
    func malformedVariantOverrideThrows(_ values: [String]) {
        let options = LaunchOptions.commandLineOptionsContainer(for: ["", "--studyVariant"] + values)
        #expect(throws: LaunchOptionDecodingError.self) {
            try options._decode(.studyVariant)
        }
    }
}

#endif
