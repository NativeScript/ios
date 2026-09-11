// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NativeScriptSDK",
    platforms: [.tvOS(.v13)],
    products: [.library(name: "NativeScript", targets: ["NativeScript", "TKLiveSync"])],
    targets: [
        .binaryTarget(name: "NativeScript", path: "NativeScript.xcframework.zip"),
        .binaryTarget(name: "TKLiveSync", path: "TKLiveSync.xcframework.zip"),
    ]
)
