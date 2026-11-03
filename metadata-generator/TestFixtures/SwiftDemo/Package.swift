// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftDemo",
    platforms: [ .iOS(.v15) ],
    products: [
        .library(name: "SwiftDemo", targets: ["SwiftDemo"]),
        // The generated NativeScript thunks, compiled as their own module so
        // they reach SwiftDemo only through its public interface.
        .library(name: "SwiftDemoInterop", targets: ["SwiftDemoInterop"]),
    ],
    targets: [
        .target(name: "SwiftDemo", path: "Sources/SwiftDemo"),
        .target(name: "SwiftDemoInterop", dependencies: ["SwiftDemo"], path: "Interop"),
    ]
)
