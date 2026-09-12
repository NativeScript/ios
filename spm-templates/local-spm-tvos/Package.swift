// swift-tools-version: 5.10
// Local SwiftPM package embedded in @nativescript/tvos packages built with
// NS_SPM_MODE=embedded (the default outside the release pipeline). Product and
// target names mirror the tvOS half of the released
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
        .tvOS(.v13),
    ],
    products: [
        // tvOS family (appletvos + appletvsimulator)
        .library(name: "NativeScriptTvOS", targets: ["NativeScriptTvOS", "TKLiveSyncTvOS"]),
    ],
    targets: [
        .binaryTarget(name: "NativeScriptTvOS", path: "NativeScript.tvos.xcframework.zip"),
        .binaryTarget(name: "TKLiveSyncTvOS", path: "TKLiveSync.tvos.xcframework.zip"),
    ]
)
