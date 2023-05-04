const semver = require("semver");
const child_process = require("child_process");
const dayjs = require("dayjs");

const currentVersion =
  process.env.NPM_VERSION || require("../package.json").version;

if (!currentVersion) {
  throw new Error("Invalid current version");
}
const currentTag = process.env.NPM_TAG || "next";
const runID = process.env.GITHUB_RUN_ID || 0;

const preRelease = `${currentTag}.${dayjs().format("YYYY-MM-DD")}-${runID}`;

let lastTagVersion = (
  process.env.LAST_TAGGED_VERSION ||
  child_process
    .spawnSync("git", ["describe", "--tags", "--abbrev=0", "--match=v*"])
    .stdout.toString()
)
  .trim()
  .substring(1);
if (!semver.parse(lastTagVersion)) {
  throw new Error("Invalid last tag version");
}

function setPreRelease(version) {
  const parsed = semver.parse(version);
  return semver.parse(
    `${parsed.major}.${parsed.minor}.${parsed.patch}-${preRelease}`
  );
}

let nextVersion = setPreRelease(currentVersion);

if (!nextVersion) {
  throw new Error("Invalid next version");
}

if (semver.compare(currentVersion, lastTagVersion) <= 0) {
  // next version is older than current version
  nextVersion = setPreRelease(semver.parse(lastTagVersion).inc("patch"));
}

if (!nextVersion) {
  throw new Error("Invalid next version");
}

console.log(nextVersion.format());
