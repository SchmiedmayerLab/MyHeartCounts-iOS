// swift-tools-version: 6.2
//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import PackageDescription


var packageDeps: [Package.Dependency] = [
    .package(
        url: "https://github.com/SchmiedmayerLab/Grove.git",
        .upToNextMinor(from: "0.3.0-beta.12")
    ),
    .package(url: "https://github.com/SchmiedmayerLab/MyHeartCounts-StudyDefinitions.git", revision: "9a9abf75f426c019a3a3b238147a6f15731f3cdc"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0")
]

#if !os(Linux)
packageDeps += [
    .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols.git", from: "7.0.0")
]
#endif

let commonSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault")
]

/// Keeps the study definition stack out of the watch app, which doesn't use it.
///
/// The stack depends on FHIRModels. Linking a Swift module keeps all of its types in the binary, used or not,
/// so these dependencies added about 35–45 MB of FHIR code to each architecture slice of the watch app.
/// The source files that use them are guarded with `#if !os(watchOS)` to match.
let notOnWatchOS: TargetDependencyCondition? = .when(platforms: [.iOS, .macOS, .linux])

/// The `MyHeartCountsShared` SPM package
let package = Package(
    name: "MyHeartCountsShared",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v15) // for the CLI target
    ],
    products: [
        .library(name: "MyHeartCountsShared", targets: ["MyHeartCountsShared"]),
        .executable(name: "SensorKitCLI", targets: ["SensorKitCLI"])
    ],
    dependencies: packageDeps,
    targets: [
        .systemLibrary(
            name: "MyHeartCountsCZlib",
            path: "Sources/CZlib",
            pkgConfig: "zlib",
            providers: [.apt(["zlib1g-dev"])]
        ),
        .target(
            name: "MyHeartCountsShared",
            dependencies: { () -> [Target.Dependency] in
                var deps: [Target.Dependency] = [
                    .product(name: "GroveFoundation", package: "Grove"),
                    .product(name: "MHCStudyDefinition", package: "MyHeartCounts-StudyDefinitions", condition: notOnWatchOS),
                    // Apple's SDKs ship zlib as a module of their own.
                    .target(name: "MyHeartCountsCZlib", condition: .when(platforms: [.linux]))
                ]
                #if !os(Linux)
                deps += [
                    .product(name: "GroveStudyDefinition", package: "Grove", condition: notOnWatchOS),
                    .product(name: "SFSafeSymbols", package: "SFSafeSymbols", condition: notOnWatchOS)
                ]
                #endif
                return deps
            }(),
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "SensorKitCLI",
            dependencies: [
                "MyHeartCountsShared",
                .product(name: "GroveSensorKitFHIR", package: "Grove"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "MyHeartCountsSharedTests",
            dependencies: ["MyHeartCountsShared"]
        )
    ]
)
