// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CombineBonjour",
    platforms: [
        .iOS(.v13), .tvOS(.v13), .macOS(.v10_15), .watchOS(.v6)
    ],
    products: [
        .library(name: "CombineBonjour", targets: ["CombineBonjour"]),
        .library(name: "CombineBonjourDynamic", type: .dynamic, targets: ["CombineBonjour"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(name: "CombineBonjour"),
        .testTarget(name: "CombineBonjourTests", dependencies: ["CombineBonjour"])
    ]
)
