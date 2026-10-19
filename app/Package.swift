// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinopsTerminal",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18)],
    products: [
        .executable(name: "FinopsTerminal", targets: ["FinopsTerminal"]),
        .library(name: "FinopsCore", targets: ["FinopsCore"]),
        .library(name: "FinopsUI", targets: ["FinopsUI"]),
        .library(name: "FinopsDash", targets: ["FinopsDash"]),
        .library(name: "FinopsRemote", targets: ["FinopsRemote"]),
    ],
    targets: [
        .target(name: "FinopsCore"),
        // world-land.json: Natural Earth 110m land outlines (public domain), for the world map.
        .target(name: "FinopsDash", dependencies: ["FinopsCore"], resources: [.process("Resources")]),
        .target(name: "FinopsUI", dependencies: ["FinopsCore", "FinopsDash"]),
        .target(name: "FinopsRemote", dependencies: ["FinopsCore"]),
        .executableTarget(name: "FinopsTerminal", dependencies: ["FinopsCore", "FinopsUI", "FinopsRemote"]),
        .testTarget(name: "FinopsCoreTests", dependencies: ["FinopsCore", "FinopsRemote"]),
    ]
)
