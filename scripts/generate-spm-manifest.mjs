#!/usr/bin/env node
// Generate ios-spm/Package.swift for a release.
//
// ensure binaryTarget whose Release asset was never uploaded breaks
// resolution for every consumer of that version. Here, the visionOS
// product/targets are emitted only when the visionOS checksums are provided.
//
// Checksums come from the KEY=sha256 env files produced by
// build_spm_artifacts.sh (one file per platform). The iOS checksums are always
// required. --strict additionally requires the visionOS checksums; pass it for
// every non-"next" release so a real release can never silently ship an
// iOS-only manifest.
//
// Usage:
//   node scripts/generate-spm-manifest.mjs \
//     --package /path/to/ios-spm/Package.swift \
//     --version 9.1.0 \
//     --checksums checksums-ios.env [--checksums checksums-visionos.env] \
//     [--strict]
import fs from "node:fs";

const args = process.argv.slice(2);
const opts = { checksums: [] };
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--package") opts.package = args[++i];
  else if (a === "--version") opts.version = args[++i];
  else if (a === "--checksums") opts.checksums.push(args[++i]);
  else if (a === "--strict") opts.strict = true;
  else {
    console.error(`Unknown argument: ${a}`);
    process.exit(1);
  }
}

if (!opts.package || !opts.version || opts.checksums.length === 0) {
  console.error(
    "Usage: generate-spm-manifest.mjs --package <Package.swift> --version <v> --checksums <file> [--checksums <file>] [--strict]"
  );
  process.exit(1);
}

// The version is interpolated into Swift source and into a release URL; accept
// semver (with optional prerelease) and nothing else.
const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
if (!VERSION_RE.test(opts.version)) {
  console.error(`ERROR: "${opts.version}" is not a valid release version`);
  process.exit(1);
}

const IOS_KEYS = ["NS_CHECKSUM_NATIVESCRIPT_IOS", "NS_CHECKSUM_TKLIVESYNC_IOS"];
const VISION_KEYS = [
  "NS_CHECKSUM_NATIVESCRIPT_VISIONOS",
  "NS_CHECKSUM_TKLIVESYNC_VISIONOS",
];
const KNOWN_KEYS = new Set([...IOS_KEYS, ...VISION_KEYS]);

// A binaryTarget checksum must be a 64-char lowercase hex SHA-256. Reject
// anything else now (empty/truncated/uppercase) so we can't emit a manifest
// that resolves to a checksum mismatch later.
const SHA256_RE = /^[0-9a-f]{64}$/;
const checksums = {};
for (const file of opts.checksums) {
  const text = fs.readFileSync(file, "utf8");
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (!key) continue;
    if (!KNOWN_KEYS.has(key)) {
      console.error(`ERROR: unknown checksum key ${key} in ${file}`);
      process.exit(1);
    }
    if (!SHA256_RE.test(value)) {
      console.error(
        `ERROR: ${key} in ${file} is not a valid SHA-256 checksum: "${value}"`
      );
      process.exit(1);
    }
    checksums[key] = value;
  }
}

const missingIos = IOS_KEYS.filter((k) => !(k in checksums));
if (missingIos.length) {
  console.error(`ERROR: missing iOS checksums: ${missingIos.join(", ")}`);
  process.exit(1);
}

const presentVision = VISION_KEYS.filter((k) => k in checksums);
if (presentVision.length !== 0 && presentVision.length !== VISION_KEYS.length) {
  const missing = VISION_KEYS.filter((k) => !(k in checksums));
  console.error(
    `ERROR: partial visionOS checksums — have ${presentVision.join(", ")} but missing ${missing.join(", ")}`
  );
  process.exit(1);
}
const includeVision = presentVision.length === VISION_KEYS.length;
if (opts.strict && !includeVision) {
  console.error(
    "ERROR: --strict requires the visionOS checksums (a non-next release must ship the full manifest)"
  );
  process.exit(1);
}

const visionPlatform = includeVision ? `\n        .visionOS(.v1),` : "";
const visionProduct = includeVision
  ? `\n        // visionOS family (xros + xrsimulator)
        .library(name: "NativeScriptVisionOS", targets: ["NativeScriptVisionOS", "TKLiveSyncVisionOS"]),`
  : "";
const visionTargets = includeVision
  ? `
        .binaryTarget(
            name: "NativeScriptVisionOS",
            url: "\\(releaseBase)/NativeScript.visionos.xcframework.zip",
            checksum: "${checksums.NS_CHECKSUM_NATIVESCRIPT_VISIONOS}"
        ),
        .binaryTarget(
            name: "TKLiveSyncVisionOS",
            url: "\\(releaseBase)/TKLiveSync.visionos.xcframework.zip",
            checksum: "${checksums.NS_CHECKSUM_TKLIVESYNC_VISIONOS}"
        ),`
  : "";

const manifest = `// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// GENERATED FILE — DO NOT EDIT BY HAND.
// Emitted per release by scripts/generate-spm-manifest.mjs in
// github.com/NativeScript/ios. The target set mirrors the assets the release
// publishes: the rolling "next" channel builds iOS only, so its manifests omit
// the visionOS product/targets (SwiftPM eagerly downloads every binaryTarget
// in a resolved manifest, and a target without an uploaded asset would break
// resolution for every consumer of that version).
//
// Copyright OpenJS Foundation and other contributors, https://openjsf.org
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import PackageDescription

let nsVersion = "${opts.version}"
let releaseBase = "https://github.com/NativeScript/ios/releases/download/v\\(nsVersion)"

let package = Package(
    name: "NativeScriptSDK",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),${visionPlatform}
    ],
    products: [
        // iOS family (iphoneos + iphonesimulator + Mac Catalyst)
        .library(name: "NativeScript", targets: ["NativeScript", "TKLiveSync"]),
        // Backwards-compatible alias for the historical product name.
        .library(name: "NativeScriptSDK", targets: ["NativeScript", "TKLiveSync"]),${visionProduct}
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "NativeScript",
            url: "\\(releaseBase)/NativeScript.xcframework.zip",
            checksum: "${checksums.NS_CHECKSUM_NATIVESCRIPT_IOS}"
        ),
        .binaryTarget(
            name: "TKLiveSync",
            url: "\\(releaseBase)/TKLiveSync.xcframework.zip",
            checksum: "${checksums.NS_CHECKSUM_TKLIVESYNC_IOS}"
        ),${visionTargets}
    ]
)
`;

fs.writeFileSync(opts.package, manifest);

console.log(`Generated ${opts.package}`);
console.log(`  version: ${opts.version}`);
console.log(`  targets: iOS${includeVision ? " + visionOS" : " only (no visionOS checksums provided)"}`);
