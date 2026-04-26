// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PoolChat",
    platforms: [.iOS(.v18), .macOS(.v14)],
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
        .testTarget(
            name: "PoolChatTests",
            dependencies: ["PoolChat"],
            path: "Tests/PoolChatTests"
        ),
    ]
)
