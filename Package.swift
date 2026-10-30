// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MetalFlow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MetalFlowCore", targets: ["MetalFlowCore"]),
        .executable(name: "mflow", targets: ["mflow"]),
    ],
    targets: [
        .target(name: "MetalFlowCore"),
        .executableTarget(name: "mflow", dependencies: ["MetalFlowCore"]),
        .testTarget(
            name: "MetalFlowCoreTests",
            dependencies: ["MetalFlowCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
