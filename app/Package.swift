// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinopsTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FinopsTerminal", targets: ["FinopsTerminal"]),
    ],
    targets: [
        .target(name: "FinopsCore"),
        .target(name: "FinopsUI", dependencies: ["FinopsCore"]),
        .executableTarget(name: "FinopsTerminal", dependencies: ["FinopsCore", "FinopsUI"]),
        .testTarget(name: "FinopsCoreTests", dependencies: ["FinopsCore"]),
    ]
)
