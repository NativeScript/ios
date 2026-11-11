#!/usr/bin/env node
// Copies the npm packages the TestRunner app loads at runtime from the repo's
// node_modules into a folder inside TestRunner/app, which Xcode bundles as-is.
// Invoked by the TestRunner target's "Stage Test Runner Dependencies" phase.

import { createRequire } from "node:module";
import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const usage = `Usage: node tools/stage-test-runner-deps.mjs --out-dir <dir>

Copies the TestRunner app's npm dependencies into <dir>.

  --out-dir <dir>  destination folder (created if missing)
  -h, --help       show this help`;

// Each package's files are copied flat into <out-dir>/<name>/.
const PACKAGES = [
  { name: "jasmine-core", files: ["lib/jasmine-core/jasmine.js", "LICENSE"] },
];

let values;
try {
  ({ values } = parseArgs({
    options: {
      "out-dir": { type: "string" },
      help: { type: "boolean", short: "h" },
    },
    strict: true,
  }));
} catch (e) {
  console.error(`error: ${e.message}\n\n${usage}`);
  process.exit(1);
}
if (values.help) {
  console.log(usage);
  process.exit(0);
}
if (!values["out-dir"]) {
  console.error(`error: --out-dir is required\n\n${usage}`);
  process.exit(1);
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const requireFromRepo = createRequire(join(repoRoot, "package.json"));
const outDir = resolve(values["out-dir"]);

// Packages may restrict `exports` to their entry point, so the package root is
// found by walking up from the resolved entry to its package.json.
function packageRoot(name) {
  let entry;
  try {
    entry = requireFromRepo.resolve(name);
  } catch {
    console.error(`error: ${name} is not installed. Run 'npm install' in ${repoRoot}.`);
    process.exit(1);
  }
  for (let dir = dirname(entry); dir !== dirname(dir); dir = dirname(dir)) {
    const manifest = join(dir, "package.json");
    if (existsSync(manifest) && JSON.parse(readFileSync(manifest, "utf8")).name === name) {
      return dir;
    }
  }
  console.error(`error: could not find the package root of ${name} from ${entry}`);
  process.exit(1);
}

// Unchanged files keep their mtime so Xcode does not recopy the app folder.
function copyIfChanged(from, to) {
  if (existsSync(to) && readFileSync(to).equals(readFileSync(from))) {
    return false;
  }
  mkdirSync(dirname(to), { recursive: true });
  copyFileSync(from, to);
  return true;
}

for (const pkg of PACKAGES) {
  const root = packageRoot(pkg.name);
  for (const file of pkg.files) {
    const from = join(root, file);
    const to = join(outDir, pkg.name, file.split("/").pop());
    if (copyIfChanged(from, to)) {
      console.log(`staged ${pkg.name}/${file} -> ${to}`);
    }
  }
}
