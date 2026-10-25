// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The app worker supplies this directory after the standalone core is established.
var products: [Product] = [
    .library(name: "PromptpadCore", targets: ["PromptpadCore"]),
    .library(name: "PromptpadVoice", targets: ["PromptpadVoice"])
]
var targets: [Target] = [
    .target(name: "PromptpadCore", exclude: ["CONTRACT.md"]),
    .testTarget(name: "PromptpadCoreTests", dependencies: ["PromptpadCore"]),
    .target(name: "PromptpadVoice", dependencies: ["PromptpadCore"]),
    .testTarget(name: "PromptpadVoiceTests", dependencies: ["PromptpadVoice", "PromptpadCore"])
]
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
if FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Sources/PromptpadApp").path) {
    products.append(.executable(name: "Promptpad", targets: ["PromptpadApp"]))
    targets.append(.executableTarget(name: "PromptpadApp", dependencies: ["PromptpadCore", "PromptpadVoice"]))
    targets.append(.testTarget(name: "PromptpadAppTests", dependencies: ["PromptpadApp", "PromptpadCore"]))
}

let package = Package(name: "Promptpad", platforms: [.macOS(.v13)], products: products, targets: targets)
