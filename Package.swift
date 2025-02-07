// swift-tools-version:5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CombineBonjour",
    platforms: [
        .iOS(.v13), .tvOS(.v13), .macOS(.v10_15), .watchOS(.v6)
    ],
    products: [
        .library(name: "CombineBonjour", targets: ["CombineBonjour"]),
        .library(name: "CombineBonjourDynamic", type: .dynamic, targets: ["CombineBonjour"])
    ],
    dependencies: [
        .package(url: "https://github.com/teufelaudio/NetworkExtensions.git", from: "2.0.0")
    ],
    targets: [
        .target(name: "CombineBonjour", dependencies: ["NetworkExtensions"]),
        .target(name: "CombineBonjourDynamic", dependencies: [.product(name: "NetworkExtensionsDynamic", package: "NetworkExtensions")])
    ]
)
