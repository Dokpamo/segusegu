// swift-tools-version: 6.2

import PackageDescription
import Foundation

let binaryPath = "Artifacts/LorepiaCore.xcframework"
let hasGeneratedCore = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(binaryPath)
        .path
)

let lorepiaKitTarget: Target = if hasGeneratedCore {
    .target(
        name: "LorepiaKit",
        dependencies: ["LorepiaCoreFFI"],
        swiftSettings: [.define("LOREPIA_UNIFFI_GENERATED")]
    )
} else {
    .target(
        name: "LorepiaKit",
        exclude: ["Bridge/Generated"]
    )
}

var packageTargets: [Target] = [lorepiaKitTarget]
if hasGeneratedCore {
    packageTargets.append(
        .binaryTarget(name: "LorepiaCoreFFI", path: binaryPath)
    )
}
packageTargets.append(
    .testTarget(
        name: "LorepiaKitTests",
        dependencies: ["LorepiaKit"],
        swiftSettings: hasGeneratedCore
            ? [.define("LOREPIA_UNIFFI_GENERATED")]
            : []
    )
)

let package = Package(
    name: "LorepiaKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LorepiaKit", targets: ["LorepiaKit"]),
    ],
    targets: packageTargets
)
