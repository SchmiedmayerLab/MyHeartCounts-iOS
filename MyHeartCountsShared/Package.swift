// swift-tools-version: 6.2

//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//


import PackageDescription


var packageDeps: [Package.Dependency] = [
    .package(url: "https://github.com/StanfordSpezi/SpeziFoundation.git", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.93.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0")
]

#if !os(Linux)
packageDeps += [
    .package(url: "https://github.com/StanfordSpezi/SpeziStudy.git", from: "0.1.20"),
    .package(url: "https://github.com/StanfordSpezi/SpeziStorage.git", from: "2.1.4"), // not actually used but we need to force the version until we update SpeziStudy
    .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols.git", from: "7.0.0")
]
#endif

/// dependencies of the `MyHeartCountsShared` target
var mhcSharedTargetDeps: [Target.Dependency] = [
    .product(name: "SpeziFoundation", package: "SpeziFoundation"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOFoundationCompat", package: "swift-nio")
]

#if !os(Linux)
mhcSharedTargetDeps += [
    .product(name: "SpeziStudyDefinition", package: "SpeziStudy"),
    .product(name: "SFSafeSymbols", package: "SFSafeSymbols")
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
            dependencies: mhcSharedTargetDeps,
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "SensorKitCLI",
            dependencies: [
                "MyHeartCountsShared",
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
