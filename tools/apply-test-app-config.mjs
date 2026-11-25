#!/usr/bin/env node
// Writes the TestRunner app's package.json into the built app bundle, with
// per-run overrides applied. Invoked by the TestRunner target's "Apply Test App
// Config" phase, which runs after Copy Bundle Resources.

import { readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";

const MODES = ["resurrecting", "rooted", "canary"];
const SCOPES = ["extended", "all"];

const usage = `Usage: node tools/apply-test-app-config.mjs --source <file> --out <file> [options]

Writes <source> to <out>, applying the given overrides.

  --source <file>                    the app's package.json in the source tree
  --out <file>                       the package.json inside the built app bundle
  --wrapper-lifetime <mode>[:<scope>]
                                     set "wrapperLifetime": { mode, scope }
                                     mode: ${MODES.join(" | ")}
                                     scope: ${SCOPES.join(" | ")} (default: extended)
  -h, --help                         show this help`;

function fail(message) {
  console.error(`error: ${message}\n\n${usage}`);
  process.exit(1);
}

let values;
try {
  ({ values } = parseArgs({
    options: {
      source: { type: "string" },
      out: { type: "string" },
      "wrapper-lifetime": { type: "string" },
      help: { type: "boolean", short: "h" },
    },
    strict: true,
  }));
} catch (e) {
  fail(e.message);
}
if (values.help) {
  console.log(usage);
  process.exit(0);
}
if (!values.source || !values.out) {
  fail("--source and --out are required");
}

const source = readFileSync(values.source, "utf8");
let output = source;

const lifetime = values["wrapper-lifetime"];
if (lifetime !== undefined) {
  const [mode, scope = "extended", ...rest] = lifetime.split(":");
  if (rest.length || !MODES.includes(mode) || !SCOPES.includes(scope)) {
    fail(`invalid --wrapper-lifetime '${lifetime}'`);
  }
  const config = JSON.parse(source);
  config.wrapperLifetime = { ...config.wrapperLifetime, mode, scope };
  output = `${JSON.stringify(config, null, 4)}\n`;
  console.log(`wrapperLifetime: ${mode}/${scope}`);
}

// The bundle copy is rewritten on every build, override or not: Xcode skips
// re-copying an unchanged app folder, so an override from an earlier build
// would otherwise survive into the next one.
let current = null;
try {
  current = readFileSync(values.out, "utf8");
} catch {}
if (current !== output) {
  writeFileSync(values.out, output);
}
