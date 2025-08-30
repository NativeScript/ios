// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftDemo",
    platforms: [ .iOS(.v15) ],
    products: [ .library(name: "SwiftDemo", targets: ["SwiftDemo"]) ],
    targets: [
        .target(name: "SwiftDemo", path: "Sources")
    ]
)
