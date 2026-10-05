// swift-tools-version: 5.10
// Local SwiftPM package embedded in @nativescript/ios packages built with
// NS_SPM_MODE=embedded (the default outside the release pipeline). Same
// product names as the released github.com/NativeScript/ios-spm manifest, but
// the binary targets point at the xcframework zips packed next to this
// manifest (framework/internal/local-spm), so the npm package is fully
// self-contained and portable. Only CLI apps consume this package, and they
// link their own metadata, so unlike ios-spm's NativeScriptSDK product nothing
// here bundles NativeScriptDefaultMetadata.
//
// The frameworks are zipped because npm strips symlinks (the Mac Catalyst
// slices contain them); SwiftPM extracts local zip binary targets itself.
import PackageDescription

let package = Package(
    name: "NativeScriptSDK",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
    ],
    products: [
        // iOS family (iphoneos + iphonesimulator + Mac Catalyst)
        .library(name: "NativeScript", targets: ["NativeScript", "TKLiveSync"]),
        // Backwards-compatible alias for the historical product name.
        .library(name: "NativeScriptSDK", targets: ["NativeScript", "TKLiveSync"]),
    ],
    targets: [
        .binaryTarget(name: "NativeScript", path: "NativeScript.xcframework.zip"),
        .binaryTarget(name: "TKLiveSync", path: "TKLiveSync.xcframework.zip"),
    ]
)
