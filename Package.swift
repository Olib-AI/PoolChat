// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PoolChat",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PoolChat", targets: ["PoolChat"]),
    ],
    dependencies: [
        .package(path: "../ConnectionPool"),
    ],
    targets: [
        .target(
            name: "PoolChat",
            dependencies: ["ConnectionPool"],
            path: "Sources"
        ),
    ]
)
