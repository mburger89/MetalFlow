// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MetalFlow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MetalFlowCore", targets: ["MetalFlowCore"]),
        .library(name: "MetalFlowKit", targets: ["MetalFlowKit"]),
        .executable(name: "mflow", targets: ["mflow"]),
        .executable(name: "MetalFlow", targets: ["MetalFlow"]),
    ],
    dependencies: [
        .package(name: "MetalUI", path: "../MetalUI", traits: [.defaults]),
    ],
    targets: [
        .target(name: "MetalFlowCore"),
        .executableTarget(name: "mflow", dependencies: ["MetalFlowCore"]),
        // Everything but the entry point, so a test imports it plainly (Jotter's layout).
        .target(
            name: "MetalFlowKit",
            dependencies: [
                "MetalFlowCore",
                .product(name: "MetalUI", package: "MetalUI"),
            ]
        ),
        .executableTarget(
            name: "MetalFlow",
            dependencies: [
                "MetalFlowKit",
                "MetalFlowCore",
                .product(name: "MetalUI", package: "MetalUI"),
                // On every platform (SG-D): a target naming these fails to build on macOS
                // when they are conditional here ("unable to resolve module dependency: 'CFreeType'").
                .product(name: "MetalUIPortableText", package: "MetalUI"),
                .product(name: "MetalUISystemFonts", package: "MetalUI"),
            ]
        ),
        .testTarget(
            name: "MetalFlowCoreTests",
            dependencies: ["MetalFlowCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "mflowTests", dependencies: ["mflow", "MetalFlowCore"]),
        .testTarget(
            name: "MetalFlowKitTests",
            dependencies: [
                "MetalFlowKit",
                "MetalFlowCore",
                .product(name: "MetalUI", package: "MetalUI"),
                .product(name: "MetalUITesting", package: "MetalUI"),
                .product(name: "MetalUIPortableText", package: "MetalUI"),
                .product(name: "MetalUISystemFonts", package: "MetalUI"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
