#!/usr/bin/env node
// Stamp the runtime version into a packaged project template's SwiftPM reference.
//
// The source templates ship with `version = "__NS_RUNTIME_VERSION__";` in their
// XCRemoteSwiftPackageReference. At npm-pack time we replace that placeholder
// with the concrete version being published, so `@nativescript/ios@X` always
// resolves the matching `ios-spm` tag `X` (and therefore the xcframework built
// for X). The {N} CLI copies the stamped template verbatim — no CLI change.
//
// Usage: node scripts/stamp-template-version.mjs <project.pbxproj> <version>
import fs from "node:fs";

const [, , pbxPath, version] = process.argv;

if (!pbxPath || !version) {
  console.error("Usage: stamp-template-version.mjs <project.pbxproj> <version>");
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
