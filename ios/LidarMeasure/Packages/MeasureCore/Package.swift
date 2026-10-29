// swift-tools-version: 5.9
//
// MeasureCore holds every piece of the app that does not need ARKit, RealityKit or UIKit:
// geometry, the accuracy model, mesh cleanup, texture projection and the file exporters.
// Keeping it framework-free means it builds and tests with `swift test` on macOS or Linux,
// so the maths behind every number the app shows is covered by unit tests.

import PackageDescription

let package = Package(
    name: "MeasureCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeasureCore", targets: ["MeasureCore"]),
    ],
    targets: [
        .target(name: "MeasureCore"),
        .testTarget(name: "MeasureCoreTests", dependencies: ["MeasureCore"]),
    ]
)
