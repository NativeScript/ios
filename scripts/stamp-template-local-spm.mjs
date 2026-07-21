#!/usr/bin/env node
// Stamp a packaged project template to consume the runtime from the local
// SwiftPM package embedded in the npm package (framework/internal/local-spm)
// instead of the released ios-spm tag.
//
// Replaces the template's XCRemoteSwiftPackageReference (which pins
// github.com/NativeScript/ios-spm at __NS_RUNTIME_VERSION__, see
// stamp-template-version.mjs) with an XCLocalSwiftPackageReference at the
// given relative path. Xcode resolves that path relative to the project
// directory, so "internal/local-spm" keeps resolving after the {N} CLI copies
// the template into an app's platforms folder.
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";

const USAGE = `Usage: node scripts/stamp-template-local-spm.mjs <project.pbxproj> <relative-path> [--package-dir <dir>]

  <project.pbxproj>  packaged template project to stamp
  <relative-path>    path Xcode resolves relative to the project directory,
                     e.g. "internal/local-spm"
  --package-dir      on-disk location of the package being referenced; when
                     given, it must contain a Package.swift (sanity check that
                     the packaging step actually embedded the package)
  -h, --help         show this help`;

let values, positionals;
try {
  ({ values, positionals } = parseArgs({
    options: {
      "package-dir": { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
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

const [pbxPath, stampPath] = positionals;
if (!pbxPath || !stampPath || positionals.length > 2) {
  console.error(USAGE);
  process.exit(1);
}

const packageDir = values["package-dir"];
if (packageDir && !fs.existsSync(path.join(packageDir, "Package.swift"))) {
  console.error(`No Package.swift found in ${packageDir} — was the local SwiftPM package embedded?`);
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
\t\t\trelativePath = ${JSON.stringify(stampPath)};
\t\t};
/* End XCLocalSwiftPackageReference section */`
);

// Update the comment annotations everywhere the reference UUID appears
// (packageReferences list + XCSwiftPackageProductDependency).
contents = contents.split(`${refUuid} /* XCRemoteSwiftPackageReference "ios-spm" */`).join(`${refUuid} /* XCLocalSwiftPackageReference "local-spm" */`);

fs.writeFileSync(pbxPath, contents);
console.log(`Stamped ${pbxPath} → local SwiftPM package at ${stampPath}`);
