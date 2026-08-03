// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VexaniumKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "VexaniumKit", targets: ["VexaniumKit"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/21-DOT-DEV/swift-secp256k1",
            from: "0.9.2"
        ),
    ],
    targets: [
        .target(
            name: "VexaniumKit",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "libsecp256k1", package: "swift-secp256k1"),
            ]
        ),
        .testTarget(
            name: "VexaniumKitTests",
            dependencies: ["VexaniumKit"]
        ),
    ]
)
