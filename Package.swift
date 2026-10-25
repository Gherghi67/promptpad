// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The app worker supplies this directory after the standalone core is established.
var products: [Product] = [
    .library(name: "GamepadTerminalCore", targets: ["GamepadTerminalCore"]),
    .library(name: "GamepadTerminalVoice", targets: ["GamepadTerminalVoice"])
]
var targets: [Target] = [
    .target(name: "GamepadTerminalCore", exclude: ["CONTRACT.md"]),
    .testTarget(name: "GamepadTerminalCoreTests", dependencies: ["GamepadTerminalCore"]),
    .target(name: "GamepadTerminalVoice", dependencies: ["GamepadTerminalCore"]),
    .testTarget(name: "GamepadTerminalVoiceTests", dependencies: ["GamepadTerminalVoice", "GamepadTerminalCore"])
]
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
if FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Sources/GamepadTerminalApp").path) {
    products.append(.executable(name: "GamepadTerminal", targets: ["GamepadTerminalApp"]))
    targets.append(.executableTarget(name: "GamepadTerminalApp", dependencies: ["GamepadTerminalCore", "GamepadTerminalVoice"]))
    targets.append(.testTarget(name: "GamepadTerminalAppTests", dependencies: ["GamepadTerminalApp", "GamepadTerminalCore"]))
}

let package = Package(name: "GamepadTerminal", platforms: [.macOS(.v13)], products: products, targets: targets)
