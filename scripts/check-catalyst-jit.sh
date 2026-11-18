#!/bin/bash
# Re-sign a built Mac Catalyst TestRunner.app into the signing and app-config
# combinations the runtime's launch-time JIT decision has to handle, run the
# suite in each, and fail if a run crashes, hangs or reports a failing spec.
#
#   no-jit-entitlement          hardened, no JIT entitlement  -> must run jitless
#   jit-off-in-config           allow-jit, "ios": {"jit": false} -> must run jitless
#   unsigned-executable-memory  allow-unsigned-executable-memory -> must JIT
#
# The app is launched directly, not through XCUITest, so this needs no
# Automation Mode. CFFIXED_USER_HOME keeps the junit report TNSSaveResults
# writes to ~/Documents inside the output folder.
set -euo pipefail

usage() {
  echo "Usage: ./scripts/check-catalyst-jit.sh --app <TestRunner.app> --output <dir> [--timeout <seconds>]"
  echo ""
  echo "  --app <path>         Mac Catalyst TestRunner.app to re-sign (left untouched; copies are signed)"
  echo "  --output <dir>       folder for the re-signed copies, <variant>.log and <variant>-junit.xml"
  echo "  --timeout <seconds>  per-variant limit for the suite to report (default: 600)"
  echo "  -h, --help           show this help"
}

APP=""
OUTPUT=""
TIMEOUT=600
while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      [ $# -ge 2 ] || { echo "--app needs a value" >&2; usage >&2; exit 1; }
      APP="$2"
      shift 2
      ;;
    --output)
      [ $# -ge 2 ] || { echo "--output needs a value" >&2; usage >&2; exit 1; }
      OUTPUT="$2"
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || { echo "--timeout needs a value" >&2; usage >&2; exit 1; }
      TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[ -n "$APP" ] && [ -n "$OUTPUT" ] || { usage >&2; exit 1; }
[ -x "$APP/Contents/MacOS/TestRunner" ] || { echo "$APP is not a Mac Catalyst TestRunner.app" >&2; exit 1; }
case "$TIMEOUT" in
  ''|*[!0-9]*) echo "--timeout must be a number of seconds" >&2; exit 1 ;;
esac

mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)

APP_PID=""
trap '[ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; true' EXIT

write_entitlements() {
  local file="$1" entitlement
  shift
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    for entitlement in "$@"; do
      echo "  <key>com.apple.security.cs.$entitlement</key><true/>"
    done
    echo '</dict></plist>'
  } > "$file"
}

# run_variant <name> <expect: jit|jitless> <ios.jit value or ""> <entitlement>...
# Called as `run_variant ... || ...`, which turns off set -e inside it, so every
# step that can fail returns explicitly.
run_variant() {
  local name="$1" expect="$2" config_jit="$3"
  shift 3
  local dir="$OUTPUT/$name"
  local app="$dir/TestRunner.app"
  local report="$dir/home/Documents/junit-result.xml"
  local log="$OUTPUT/$name.log"

  echo "---- $name: expecting $expect"
  rm -rf "$dir" "$log" "$OUTPUT/$name-junit.xml"
  mkdir -p "$dir/home/Documents"
  ditto "$APP" "$app" || return 1

  if [ -n "$config_jit" ]; then
    node -e '
      const fs = require("fs");
      const [file, jit] = process.argv.slice(1);
      const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
      pkg.ios = Object.assign({}, pkg.ios, { jit: jit === "true" });
      fs.writeFileSync(file, JSON.stringify(pkg, null, 4));
    ' "$app/Contents/Resources/app/package.json" "$config_jit" || return 1
  fi

  # Library validation would reject the ad-hoc signed embedded frameworks.
  write_entitlements "$dir/entitlements.plist" disable-library-validation "$@" || return 1
  codesign --force --options runtime --entitlements "$dir/entitlements.plist" --sign - "$app" 2>/dev/null || return 1
  codesign --verify --strict "$app" || return 1
  local signature
  signature=$(codesign -dv "$app" 2>&1) || return 1
  if ! printf '%s\n' "$signature" | grep -q 'flags=.*runtime'; then
    echo "$name: re-signed app lacks the hardened runtime, so the variant would test nothing" >&2
    return 1
  fi

  if [ "$expect" = "jitless" ]; then
    CFFIXED_USER_HOME="$dir/home" OS_ACTIVITY_DT_MODE=1 "$app/Contents/MacOS/TestRunner" -expect-jitless > "$log" 2>&1 &
  else
    CFFIXED_USER_HOME="$dir/home" OS_ACTIVITY_DT_MODE=1 "$app/Contents/MacOS/TestRunner" > "$log" 2>&1 &
  fi
  APP_PID=$!

  local deadline=$((SECONDS + TIMEOUT)) status=0
  while [ ! -f "$report" ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      wait "$APP_PID" || status=$?
      APP_PID=""
      echo "$name: TestRunner exited (status $status) before reporting; see $log" >&2
      return 1
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "$name: no junit report after ${TIMEOUT}s; see $log" >&2
      return 1
    fi
    sleep 2
  done
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""

  cp "$report" "$OUTPUT/$name-junit.xml"
  local tests failures
  tests=$(grep -c '<testcase ' "$report" || true)
  failures=$(grep -c -e '<failure' -e '<error' "$report" || true)
  if [ "$failures" -ne 0 ]; then
    echo "$name: $failures failing spec(s) of $tests; failing testcases:" >&2
    grep -B1 -e '<failure' -e '<error' "$report" | grep -o 'name="[^"]*"' >&2 || true
    return 1
  fi
  echo "$name: $tests specs, 0 failures"
}

FAILED=()
run_variant no-jit-entitlement jitless "" || FAILED+=(no-jit-entitlement)
run_variant jit-off-in-config jitless false allow-jit || FAILED+=(jit-off-in-config)
run_variant unsigned-executable-memory jit "" allow-unsigned-executable-memory || FAILED+=(unsigned-executable-memory)

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Failed variants: ${FAILED[*]}" >&2
  exit 1
fi
echo "All Mac Catalyst JIT variants passed."
