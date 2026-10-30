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
        revision: "6e40cfbffcecafd59b253d6d1d9e2cfbdc89b1d0"
    ),
    .package(url: "https://github.com/SchmiedmayerLab/MyHeartCounts-StudyDefinitions.git", revision: "9bcc6cc921a3914d8377a19a58cd3d2f8d877eb6"),
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
                    .product(name: "MHCStudyDefinition", package: "MyHeartCounts-StudyDefinitions"),
                    // Apple's SDKs ship zlib as a module of their own.
                    .target(name: "MyHeartCountsCZlib", condition: .when(platforms: [.linux]))
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
