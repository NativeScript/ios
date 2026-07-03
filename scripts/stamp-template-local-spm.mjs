#!/usr/bin/env node
// Stamp a packaged project template to consume the runtime via a LOCAL SwiftPM
// package instead of the released ios-spm tag (the D6 "dev/offline override"
// from SPM_DISTRIBUTION_PLAN.md).
//
// Local `npm run build-ios` produces xcframeworks in dist/ but no ios-spm
// release tag, so the template's XCRemoteSwiftPackageReference (exactVersion
// pinned by stamp-template-version.mjs) can never resolve. This script rewrites
// that reference into an XCLocalSwiftPackageReference pointing at the local-spm
// package the build just created (dist/local-spm — Package.swift + binary
// targets over the built xcframeworks).
//
// The resulting npm package is machine-specific (it embeds an absolute path
// into this checkout) and is only meant for `ns platform add ios
// --framework-path=dist/nativescript-ios-<version>.tgz` style local testing.
//
// Usage: node scripts/stamp-template-local-spm.mjs <project.pbxproj> <abs-path-to-local-spm>
import fs from "node:fs";
import path from "node:path";

const [, , pbxPath, localSpmPath] = process.argv;

if (!pbxPath || !localSpmPath) {
  console.error("Usage: stamp-template-local-spm.mjs <project.pbxproj> <abs-path-to-local-spm>");
  process.exit(1);
}

if (!path.isAbsolute(localSpmPath)) {
  console.error(`local-spm path must be absolute, got: ${localSpmPath}`);
  process.exit(1);
}

if (!fs.existsSync(path.join(localSpmPath, "Package.swift"))) {
  console.error(`No Package.swift found in ${localSpmPath} — run the runtime build first.`);
  process.exit(1);
}

let contents = fs.readFileSync(pbxPath, "utf8");

const REMOTE_REF_RE =
  /\/\* Begin XCRemoteSwiftPackageReference section \*\/[\s\S]*?\/\* End XCRemoteSwiftPackageReference section \*\//;

if (!REMOTE_REF_RE.test(contents)) {
  console.error(`No XCRemoteSwiftPackageReference section found in ${pbxPath} (already stamped local?).`);
  process.exit(1);
}

// The template uses a fixed UUID for the package reference; keep it so the
// packageReferences list and product dependency keep resolving.
const refUuidMatch = contents.match(/([0-9A-F]{24}) \/\* XCRemoteSwiftPackageReference "ios-spm" \*\//);
if (!refUuidMatch) {
  console.error(`Could not find the "ios-spm" package reference UUID in ${pbxPath}.`);
  process.exit(1);
}
const refUuid = refUuidMatch[1];

contents = contents.replace(
  REMOTE_REF_RE,
  `/* Begin XCLocalSwiftPackageReference section */
\t\t${refUuid} /* XCLocalSwiftPackageReference "local-spm" */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = ${JSON.stringify(localSpmPath)};
\t\t};
/* End XCLocalSwiftPackageReference section */`
);

// Update the comment annotations everywhere the reference UUID appears
// (packageReferences list + XCSwiftPackageProductDependency).
contents = contents.split(`${refUuid} /* XCRemoteSwiftPackageReference "ios-spm" */`).join(`${refUuid} /* XCLocalSwiftPackageReference "local-spm" */`);

fs.writeFileSync(pbxPath, contents);
console.log(`Stamped ${pbxPath} → local SwiftPM package at ${localSpmPath}`);
