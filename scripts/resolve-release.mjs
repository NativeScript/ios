#!/usr/bin/env node
// Resolve the release identity for the npm_release workflow's `setup` job and
// write it to $GITHUB_OUTPUT: NPM_VERSION, NPM_TAG, BUILD_MATRIX.
//
// Trigger shapes:
//   * workflow_dispatch with a version  -> that version (leading "v" allowed);
//     publishes "latest" unless the version is a prerelease (get-npm-tag.js)
//   * push of a v* tag                  -> version from the tag, which is
//     authoritative and must match package.json so a release can't drift
//   * push to main / dispatch w/o input -> rolling "next" prerelease
//     (get-next-version.js)
//
// The build matrix: ios always builds/publishes; visionos only for real
// releases (npm tag != "next"), never for the rolling next channel. Each entry
// carries `target` (package identity, @nativescript/<target>) and `script`
// (the npm build script; note the vision script is build-vision).
//
// GITHUB_REF and GITHUB_OUTPUT are read from the environment (GitHub's
// contract); the workflow_dispatch version input is a real argument.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

const USAGE = `Usage: node scripts/resolve-release.mjs [--version <version>]

  --version   release version to cut (leading "v" allowed); empty or omitted
              resolves from GITHUB_REF (v* tag) or falls back to a rolling
              "next" prerelease
  -h, --help  show this help`;

let values;
try {
  ({ values } = parseArgs({
    options: {
      version: { type: "string", default: "" },
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

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const runScript = (script, args = []) =>
  execFileSync(process.execPath, [path.join(scriptsDir, script), ...args])
    .toString()
    .trim();

const inputVersion = values.version.trim();
const ref = process.env.GITHUB_REF || "";

let version;
if (inputVersion) {
  version = inputVersion.replace(/^v/, "");
} else if (ref.startsWith("refs/tags/")) {
  version = ref.slice("refs/tags/".length).replace(/^v/, "");
  const pkgVersion = JSON.parse(
    fs.readFileSync(path.join(scriptsDir, "..", "package.json"), "utf8")
  ).version;
  if (version !== pkgVersion) {
    console.error(
      `::error::Tag v${version} does not match package.json version ${pkgVersion}. Bump package.json before tagging.`
    );
    process.exit(1);
  }
} else {
  version = runScript("get-next-version.js");
}

const tag = runScript("get-npm-tag.js", ["--version", version]);

const targets = [{ target: "ios", script: "build-ios" }];
if (tag !== "next") {
  targets.push({ target: "visionos", script: "build-vision" });
}
const matrix = JSON.stringify({ include: targets });

if (process.env.GITHUB_OUTPUT) {
  fs.appendFileSync(
    process.env.GITHUB_OUTPUT,
    `NPM_VERSION=${version}\nNPM_TAG=${tag}\nBUILD_MATRIX=${matrix}\n`
  );
}
console.log(`Resolved ${version} (tag: ${tag}); build targets: ${matrix}`);
