#!/usr/bin/env node
// Generate ios-spm/Package.swift for a release.
//
// A binaryTarget whose Release asset was never uploaded breaks resolution for
// every consumer of that version (SwiftPM eagerly downloads every binaryTarget
// in a resolved manifest). Here, the visionOS and tvOS products/targets are
// each emitted only when that platform's checksums are provided.
//
// Checksums come from the KEY=sha256 env files produced by
// build_spm_artifacts.sh (one file per platform), passed individually via
// --checksums and/or collected from a directory via --checksums-dir. The iOS
// checksums are always required. The visionOS and tvOS checksums are
// additionally required when the release channel is anything but "next"
// (--channel), or when --strict is passed — so a real release can never
// silently ship a manifest missing a platform its build matrix produced.
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";

const USAGE = `Usage: node scripts/generate-spm-manifest.mjs --package <Package.swift> --version <version>
         (--checksums <file> ... | --checksums-dir <dir>) [--channel <tag>] [--strict]

  --package        path to the ios-spm Package.swift to (over)write
  --version        release version the manifest pins (nsVersion + asset URLs)
  --checksums      a checksums-<target>.env file from build_spm_artifacts.sh
                   (repeatable)
  --checksums-dir  directory to scan for checksums-*.env files (e.g. the merged
                   spm-artifacts download)
  --channel        npm dist-tag of this release; any channel other than "next"
                   requires the full checksum set (implies --strict)
  --strict         require the visionOS and tvOS checksums regardless of channel
  -h, --help       show this help`;

let values;
try {
  ({ values } = parseArgs({
    options: {
      package: { type: "string" },
      version: { type: "string" },
      checksums: { type: "string", multiple: true, default: [] },
      "checksums-dir": { type: "string" },
      channel: { type: "string" },
      strict: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  }));
} catch (e) {
  console.error(e.message);
  console.error(USAGE);
  process.exit(1);
}
if (values.help) {
  console.log(USAGE);
  process.exit(0);
}

const opts = {
  package: values.package,
  version: values.version,
  checksums: [...values.checksums],
  strict: values.strict || (values.channel !== undefined && values.channel !== "next"),
};

const checksumsDir = values["checksums-dir"];
if (checksumsDir) {
  if (!fs.existsSync(checksumsDir)) {
    console.error(`ERROR: --checksums-dir ${checksumsDir} does not exist`);
    process.exit(1);
  }
  const found = fs
    .readdirSync(checksumsDir)
    .filter((f) => /^checksums-.*\.env$/.test(f))
    .sort()
    .map((f) => path.join(checksumsDir, f));
  opts.checksums.push(...found);
}

if (!opts.package || !opts.version || opts.checksums.length === 0) {
  console.error(USAGE);
  process.exit(1);
}
console.log(`Using checksum files: ${opts.checksums.join(", ")}`);

// The version is interpolated into Swift source and into a release URL; accept
// semver (with optional prerelease) and nothing else.
const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
if (!VERSION_RE.test(opts.version)) {
  console.error(`ERROR: "${opts.version}" is not a valid release version`);
  process.exit(1);
}

const IOS_KEYS = ["NS_CHECKSUM_NATIVESCRIPT_IOS", "NS_CHECKSUM_TKLIVESYNC_IOS"];
// The platforms the release matrix builds only for real releases. Each is
// emitted as a whole (platform entry + product + both binary targets) or not
// at all; `slug` is the xcframework zip infix and the checksums-<slug>.env name.
const OPTIONAL_PLATFORMS = [
  {
    name: "visionOS",
    slug: "visionos",
    keys: ["NS_CHECKSUM_NATIVESCRIPT_VISIONOS", "NS_CHECKSUM_TKLIVESYNC_VISIONOS"],
    platform: ".visionOS(.v1)",
    product: "NativeScriptVisionOS",
    targets: ["NativeScriptVisionOS", "TKLiveSyncVisionOS"],
    comment: "visionOS family (xros + xrsimulator)",
  },
  {
    name: "tvOS",
    slug: "tvos",
    keys: ["NS_CHECKSUM_NATIVESCRIPT_TVOS", "NS_CHECKSUM_TKLIVESYNC_TVOS"],
    platform: ".tvOS(.v13)",
    product: "NativeScriptTvOS",
    targets: ["NativeScriptTvOS", "TKLiveSyncTvOS"],
    comment: "tvOS family (appletvos + appletvsimulator)",
  },
];
const KNOWN_KEYS = new Set([
  ...IOS_KEYS,
  ...OPTIONAL_PLATFORMS.flatMap((p) => p.keys),
]);

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

const included = [];
for (const p of OPTIONAL_PLATFORMS) {
  const present = p.keys.filter((k) => k in checksums);
  if (present.length !== 0 && present.length !== p.keys.length) {
    const missing = p.keys.filter((k) => !(k in checksums));
    console.error(
      `ERROR: partial ${p.name} checksums — have ${present.join(", ")} but missing ${missing.join(", ")}`
    );
    process.exit(1);
  }
  if (present.length === p.keys.length) {
    included.push(p);
  } else if (opts.strict) {
    console.error(
      `ERROR: this channel requires the ${p.name} checksums (a non-next release must ship the full manifest)`
    );
    process.exit(1);
  }
}

const extraPlatforms = included.map((p) => `\n        ${p.platform},`).join("");
const extraProducts = included
  .map(
    (p) => `\n        // ${p.comment}
        .library(name: "${p.product}", targets: [${p.targets.map((t) => `"${t}"`).join(", ")}]),`
  )
  .join("");
const extraTargets = included
  .map(
    (p) => `
        .binaryTarget(
            name: "${p.targets[0]}",
            url: "\\(releaseBase)/NativeScript.${p.slug}.xcframework.zip",
            checksum: "${checksums[p.keys[0]]}"
        ),
        .binaryTarget(
            name: "${p.targets[1]}",
            url: "\\(releaseBase)/TKLiveSync.${p.slug}.xcframework.zip",
            checksum: "${checksums[p.keys[1]]}"
        ),`
  )
  .join("");

const manifest = `// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// GENERATED FILE — DO NOT EDIT BY HAND.
// Emitted per release by scripts/generate-spm-manifest.mjs in
// github.com/NativeScript/ios. The target set mirrors the assets the release
// publishes: the rolling "next" channel builds iOS only, so its manifests omit
// the visionOS and tvOS products/targets (SwiftPM eagerly downloads every
// binaryTarget in a resolved manifest, and a target without an uploaded asset
// would break resolution for every consumer of that version).
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
        .macCatalyst(.v13),${extraPlatforms}
    ],
    products: [
        // iOS family (iphoneos + iphonesimulator + Mac Catalyst)
        .library(name: "NativeScript", targets: ["NativeScript", "TKLiveSync"]),
        // Backwards-compatible alias for the historical product name.
        .library(name: "NativeScriptSDK", targets: ["NativeScript", "TKLiveSync"]),${extraProducts}
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
        ),${extraTargets}
    ]
)
`;

fs.writeFileSync(opts.package, manifest);

console.log(`Generated ${opts.package}`);
console.log(`  version: ${opts.version}`);
console.log(
  `  targets: iOS${included.length ? " + " + included.map((p) => p.name).join(" + ") : " only (no visionOS/tvOS checksums provided)"}`
);
