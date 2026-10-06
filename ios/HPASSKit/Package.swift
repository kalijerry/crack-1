// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HPASSKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HPASSKit", targets: ["HPASSKit"]),
        .executable(name: "hpass-replay", targets: ["hpass-replay"]),
    ],
    targets: [
        .target(name: "HPASSKit"),
        .executableTarget(name: "hpass-replay", dependencies: ["HPASSKit"]),
        .testTarget(name: "HPASSKitTests", dependencies: ["HPASSKit"]),
    ]
)
