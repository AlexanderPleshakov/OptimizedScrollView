// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OptimizedScrollView",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "OptimizedScrollView", targets: ["OptimizedScrollView"]),
    ],
    targets: [
        .target(name: "OptimizedScrollView"),
    ]
)
