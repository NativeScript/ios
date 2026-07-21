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
// --assert-release-manifest additionally fetches the released manifest and
// asserts it pins nsVersion to this exact version. This guards against the tag
// pointing at a STALE manifest — e.g. a commit/tag step that silently failed
// and left a prior version's nsVersion + artifact URLs/checksums in place.
// Those still resolve and checksum-pass (they're internally consistent), so
// `swift package resolve` won't catch it; the explicit assertion does.
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";

const USAGE = `Usage: node scripts/generate-spm-probe.mjs --version <version> [--dir <outdir>] [--assert-release-manifest]

  --version                  released ios-spm version to pin (exact)
  --dir                      output directory for the probe package (default: spmverify)
  --assert-release-manifest  fetch the released ios-spm manifest and assert it
                             pins nsVersion to this exact version
  -h, --help                 show this help`;

let values;
try {
  ({ values } = parseArgs({
    options: {
      version: { type: "string" },
      dir: { type: "string", default: "spmverify" },
      "assert-release-manifest": { type: "boolean", default: false },
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

if (!values.version) {
  console.error(USAGE);
  process.exit(1);
}

// The version is interpolated into Swift source; accept semver (with optional
// prerelease) and nothing else.
const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
if (!VERSION_RE.test(values.version)) {
  console.error(`ERROR: "${values.version}" is not a valid release version`);
  process.exit(1);
}

if (values["assert-release-manifest"]) {
  const url = `https://raw.githubusercontent.com/NativeScript/ios-spm/${values.version}/Package.swift`;
  const res = await fetch(url);
  if (!res.ok) {
    console.error(
      `ERROR: could not fetch ${url} (HTTP ${res.status}) — was ios-spm tagged for this release?`
    );
    process.exit(1);
  }
  const releasedManifest = await res.text();
  if (!releasedManifest.includes(`let nsVersion = "${values.version}"`)) {
    console.error(
      `ERROR: ios-spm@${values.version} does not pin nsVersion="${values.version}" (stale manifest?). Found:`
    );
    for (const line of releasedManifest.split("\n")) {
      if (line.includes("nsVersion")) console.error(`  ${line.trim()}`);
    }
    process.exit(1);
  }
  console.log(`OK: ios-spm@${values.version} pins nsVersion="${values.version}"`);
}

const manifest = `// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.iOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/NativeScript/ios-spm.git", exact: "${values.version}")
    ],
    targets: [
        .target(name: "Probe", dependencies: [.product(name: "NativeScript", package: "ios-spm")])
    ]
)
`;

fs.mkdirSync(path.join(values.dir, "Sources", "Probe"), { recursive: true });
fs.writeFileSync(path.join(values.dir, "Package.swift"), manifest);
fs.writeFileSync(
  path.join(values.dir, "Sources", "Probe", "Probe.swift"),
  "// probe\n"
);

console.log(`Generated probe package in ${values.dir} (ios-spm exact: ${values.version})`);
