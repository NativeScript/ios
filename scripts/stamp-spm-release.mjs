#!/usr/bin/env node
// Stamp the released version + artifact checksums into ios-spm/Package.swift.
//
// The manifest ships with replaceable tokens:
//   let nsVersion = "NS_SPM_VERSION"
//   checksum: "NS_CHECKSUM_NATIVESCRIPT_IOS"        (and TKLIVESYNC_IOS, *_VISIONOS)
//
// This script (run by the release flow against a checkout of NativeScript/ios-spm)
// replaces them with the version being released and the SHA-256 of each uploaded
// xcframework zip. Checksums come from one or more `KEY=sha256` env files produced
// by build_spm_artifacts.sh (one per platform: iOS job + visionOS job).
//
// Usage:
//   node scripts/stamp-spm-release.mjs \
//     --package /path/to/ios-spm/Package.swift \
//     --version 9.1.0 \
//     --checksums ios-checksums.env [--checksums vision-checksums.env] \
//     [--strict]
//
// --strict fails if any NS_SPM_VERSION / NS_CHECKSUM_* token is left unstamped
// (use it for a full iOS + visionOS release so a placeholder can never ship).
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

if (!opts.package || !opts.version) {
  console.error(
    "Usage: stamp-spm-release.mjs --package <Package.swift> --version <v> --checksums <file> [--checksums <file>] [--strict]"
  );
  process.exit(1);
}

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
    // A binaryTarget checksum must be a 64-char lowercase hex SHA-256. Reject
    // anything else now (empty/truncated/uppercase) so we can't stamp a manifest
    // that resolves to a checksum mismatch later.
    if (key.startsWith("NS_CHECKSUM_") && !SHA256_RE.test(value)) {
      console.error(
        `ERROR: ${key} in ${file} is not a valid SHA-256 checksum: "${value}"`
      );
      process.exit(1);
    }
    checksums[key] = value;
  }
}

let manifest = fs.readFileSync(opts.package, "utf8");

manifest = manifest.split("NS_SPM_VERSION").join(opts.version);

const applied = [];
for (const [key, value] of Object.entries(checksums)) {
  if (manifest.includes(key)) {
    manifest = manifest.split(key).join(value);
    applied.push(key);
  }
}

fs.writeFileSync(opts.package, manifest);

console.log(`Stamped ${opts.package}`);
console.log(`  version: ${opts.version}`);
console.log(`  checksums applied: ${applied.length ? applied.join(", ") : "(none)"}`);

const leftover = (manifest.match(/NS_SPM_VERSION|NS_CHECKSUM_[A-Z_]+/g) || []);
if (leftover.length) {
  const unique = [...new Set(leftover)];
  const msg = `Unstamped tokens remain: ${unique.join(", ")}`;
  if (opts.strict) {
    console.error(`ERROR: ${msg}`);
    process.exit(1);
  }
  console.warn(`WARNING: ${msg}`);
}
