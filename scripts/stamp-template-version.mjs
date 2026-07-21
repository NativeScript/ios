#!/usr/bin/env node
// Stamp the runtime version into a packaged project template's SwiftPM reference.
//
// The source templates ship with `version = "__NS_RUNTIME_VERSION__";` in their
// XCRemoteSwiftPackageReference. At npm-pack time we replace that placeholder
// with the concrete version being published, so `@nativescript/ios@X` always
// resolves the matching `ios-spm` tag `X` (and therefore the xcframework built
// for X). The {N} CLI copies the stamped template verbatim — no CLI change.
import fs from "node:fs";
import { parseArgs } from "node:util";

const USAGE = `Usage: node scripts/stamp-template-version.mjs <project.pbxproj> <version>

  <project.pbxproj>  packaged template project to stamp
  <version>          version to pin the ios-spm reference to (exactVersion)
  -h, --help         show this help`;

let values, positionals;
try {
  ({ values, positionals } = parseArgs({
    options: { help: { type: "boolean", short: "h", default: false } },
    allowPositionals: true,
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

const [pbxPath, version] = positionals;
if (!pbxPath || !version || positionals.length > 2) {
  console.error(USAGE);
  process.exit(1);
}

const PLACEHOLDER = "__NS_RUNTIME_VERSION__";
let contents = fs.readFileSync(pbxPath, "utf8");

if (!contents.includes(PLACEHOLDER)) {
  console.error(
    `No '${PLACEHOLDER}' placeholder found in ${pbxPath}. ` +
      `Either it was already stamped or the SwiftPM reference is missing.`
  );
  process.exit(1);
}

contents = contents.split(PLACEHOLDER).join(version);
fs.writeFileSync(pbxPath, contents);
console.log(`Stamped ${pbxPath} → ios-spm exactVersion ${version}`);
