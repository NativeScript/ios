#!/usr/bin/env node
// Generate the changelog section for a version: every commit since the
// previous stable release (the highest vX.Y.Z tag reachable from HEAD that is
// lower than the version).
//
// conventional-changelog's own tag discovery can't be used: every main push
// tags a rolling prerelease (vX.Y.Z-next.<date>-<run id>), which it treats as
// the previous release, and --skip-unstable doesn't recognize that format.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import conventionalChangelog from "conventional-changelog";
import semver from "semver";

const USAGE = `Usage: node scripts/changelog.mjs [--version <version>] [--write <file>]

  --version   version the section is for (leading "v" allowed); defaults to
              package.json's version
  --write     prepend the section to <file> instead of printing it
  -h, --help  show this help`;

let values;
try {
  ({ values } = parseArgs({
    options: {
      version: { type: "string" },
      write: { type: "string" },
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

const rootDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const version = semver.valid(
  values.version ??
    JSON.parse(fs.readFileSync(path.join(rootDir, "package.json"), "utf8"))
      .version
);
if (!version) {
  console.error(`Invalid version: ${values.version}`);
  process.exit(1);
}

const isStable = (v) => semver.valid(v) && !semver.prerelease(v);

const previousTag = execFileSync("git", ["tag", "--merged", "HEAD", "--list", "v*"], {
  cwd: rootDir,
})
  .toString()
  .split("\n")
  .filter((tag) => isStable(tag) && semver.lt(tag, version))
  .sort(semver.rcompare)[0];
if (!previousTag) {
  console.error(`No stable release tag below v${version} is reachable from HEAD.`);
  process.exit(1);
}
const currentTag = `v${version}`;

const stream = conventionalChangelog(
  { preset: "angular", releaseCount: 1 },
  { version, previousTag, currentTag },
  { from: previousTag, to: "HEAD" },
  {},
  // Without this, every prerelease tag in the range starts its own section.
  { generateOn: (commit) => isStable(commit.version) }
);

let section = "";
for await (const chunk of stream) {
  section += chunk;
}

if (values.write) {
  const file = path.resolve(values.write);
  const existing = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  fs.writeFileSync(file, section + existing);
} else {
  process.stdout.write(section);
}
