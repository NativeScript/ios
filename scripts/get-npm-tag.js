const semver = require("semver");
const { parseArgs } = require("node:util");

const USAGE = `Usage: node scripts/get-npm-tag.js [--version <version>]

  --version   version to derive the npm dist-tag from
              (default: $NPM_VERSION, then package.json)
  -h, --help  show this help`;

let values;
try {
  ({ values } = parseArgs({
    options: {
      version: { type: "string" },
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

const currentVersion =
  values.version || process.env.NPM_VERSION || require("../package.json").version;

function validateNpmTag(version) {
  const parsed = semver.parse(version);
  return (
    parsed.prerelease.length === 0 || /^[a-zA-Z]+$/.test(parsed.prerelease[0])
  );
}

function getNpmTag(version) {
  if (!validateNpmTag(version)) throw new Error("Invalid npm tag");
  const parsed = semver.parse(version);
  return parsed.prerelease[0] || "latest";
}

console.log(getNpmTag(currentVersion));
