// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DicyaninRagdoll",
    platforms: [
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "DicyaninRagdoll",
            targets: ["DicyaninRagdoll"]
        )
    ],
    targets: [
        .target(
            name: "DicyaninRagdoll",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
