// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LuluPet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LuluPet", targets: ["LuluPet"])],
    targets: [
        .target(name: "LuluCore"),
        .target(name: "LuluSync", dependencies: ["LuluCore"]),
        .executableTarget(name: "LuluPet", dependencies: ["LuluCore", "LuluSync"]),
        // No Xcode on this machine, so XCTest/swift-testing are unavailable: tests are a plain executable.
        .executableTarget(name: "LuluCoreTests", dependencies: ["LuluCore", "LuluSync"]),
    ],
    swiftLanguageModes: [.v5]
)
