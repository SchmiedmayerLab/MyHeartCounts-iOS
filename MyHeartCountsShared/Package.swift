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
        revision: "46f5ef5f08168d4c7f2d7f0710574cdebfac08b7"
    ),
    .package(url: "https://github.com/SchmiedmayerLab/MyHeartCounts-StudyDefinitions.git", revision: "3a40a9cd629082b78f5bd94a7365262fd3a83191"),
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
        .target(
            name: "MyHeartCountsShared",
            dependencies: { () -> [Target.Dependency] in
                var deps: [Target.Dependency] = [
                    .product(name: "GroveFoundation", package: "Grove"),
                    .product(name: "MHCStudyDefinition", package: "MyHeartCounts-StudyDefinitions")
                ]
                #if !os(Linux)
                deps += [
                    .product(name: "GroveStudyDefinition", package: "Grove"),
                    .product(name: "SFSafeSymbols", package: "SFSafeSymbols")
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
