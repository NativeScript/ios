// swift-tools-version: 5.10
// Local SwiftPM package embedded in @nativescript/visionos packages built with
// NS_SPM_MODE=embedded (the default outside the release pipeline). Product and
// target names mirror the visionOS half of the released
// github.com/NativeScript/ios-spm manifest (see generate-spm-manifest.mjs),
// but the binary targets point at the xcframework zips packed next to this
// manifest, so the npm package is fully self-contained and portable.
//
// The frameworks are zipped because npm strips symlinks; SwiftPM extracts
// local zip binary targets itself.
import PackageDescription

let package = Package(
    name: "NativeScriptSDK",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        // visionOS family (xros + xrsimulator)
        .library(name: "NativeScriptVisionOS", targets: ["NativeScriptVisionOS", "TKLiveSyncVisionOS"]),
    ],
    targets: [
        .binaryTarget(name: "NativeScriptVisionOS", path: "NativeScript.visionos.xcframework.zip"),
        .binaryTarget(name: "TKLiveSyncVisionOS", path: "TKLiveSync.visionos.xcframework.zip"),
    ]
)
