// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NativeScript",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "NativeScript",
            targets: ["NativeScript"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .binaryTarget(
            name: "NativeScript",
            url: "https://github.com/NativeScript/ios-v8-pod/releases/download/spm-test/NativeScript.xcframework.zip",
            checksum: "5c6a41ec023b26408ffb6474c6c748bc447958da6a08c9da68138d4841bfb5fe")
    ]
)
