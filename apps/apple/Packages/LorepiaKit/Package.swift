// swift-tools-version: 6.1

import PackageDescription

let binaryPath = "Artifacts/LorepiaCore.xcframework"
let usesGeneratedCore =
    Context.environment["LOREPIA_SKIP_GENERATED"] != "1"

let lorepiaKitTarget: Target = if usesGeneratedCore {
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
if usesGeneratedCore {
    packageTargets.append(
        .binaryTarget(name: "LorepiaCoreFFI", path: binaryPath)
    )
}
packageTargets.append(
    .testTarget(
        name: "LorepiaKitTests",
        dependencies: ["LorepiaKit"],
        swiftSettings: usesGeneratedCore
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
