#!/usr/bin/env node
// Generate a throwaway SwiftPM package that depends on ios-spm at an exact
// released version — the release workflow's verify-spm job resolves it as a
// post-publish smoke test.
//
// `swift package resolve` on the probe downloads and checksum-verifies every
// binaryTarget in that release's manifest, which is exactly the resolution
// path a consumer's xcodebuild takes on a generated app project. Because the
// released manifest's target set is channel-shaped (see
// generate-spm-manifest.mjs), the SAME probe verifies every channel: "next"
// manifests only declare the iOS artifacts, real releases also declare (and
// therefore also verify) the visionOS ones.
//
// Usage: node scripts/generate-spm-probe.mjs --version <v> [--dir spmverify]
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const opts = { dir: "spmverify" };
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--version") opts.version = args[++i];
  else if (a === "--dir") opts.dir = args[++i];
  else {
    console.error(`Unknown argument: ${a}`);
    process.exit(1);
  }
}

if (!opts.version) {
  console.error("Usage: generate-spm-probe.mjs --version <v> [--dir <outdir>]");
  process.exit(1);
}

// The version is interpolated into Swift source; accept semver (with optional
// prerelease) and nothing else.
const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
if (!VERSION_RE.test(opts.version)) {
  console.error(`ERROR: "${opts.version}" is not a valid release version`);
  process.exit(1);
}

const manifest = `// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.iOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/NativeScript/ios-spm.git", exact: "${opts.version}")
    ],
    targets: [
        .target(name: "Probe", dependencies: [.product(name: "NativeScript", package: "ios-spm")])
    ]
)
`;

fs.mkdirSync(path.join(opts.dir, "Sources", "Probe"), { recursive: true });
fs.writeFileSync(path.join(opts.dir, "Package.swift"), manifest);
fs.writeFileSync(
  path.join(opts.dir, "Sources", "Probe", "Probe.swift"),
  "// probe\n"
);

console.log(`Generated probe package in ${opts.dir} (ios-spm exact: ${opts.version})`);
