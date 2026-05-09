// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OptimizedScrollView",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "OptimizedScrollView", targets: ["OptimizedScrollView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "OptimizedScrollView",
            dependencies: [
                .product(name: "DequeModule", package: "swift-collections"),
            ]
        ),
    ]
)
