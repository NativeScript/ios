#!/bin/bash
# CI-only: waits until an available iOS simulator with the given name is listed.
# On a fresh runner CoreSimulator can still be enumerating its devices when the
# test step starts, and an xcodebuild that resolves its -destination then fails
# with "Unable to find a device matching the provided destination specifier"
# (exit code 70).
set -euo pipefail

usage() {
  echo "Usage: ./scripts/wait-for-simulator.sh --name <device name> [--timeout <seconds>]"
  echo ""
  echo "  --name <name>        simulator device name, e.g. \"iPhone 16 Pro\""
  echo "  --timeout <seconds>  give up after this long (default: 300)"
  echo "  -h, --help           show this help"
}

NAME=""
TIMEOUT=300
while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      [ $# -ge 2 ] || { echo "--name requires a value" >&2; usage >&2; exit 1; }
      NAME="$2"
      shift 2
      ;;
    --name=*)
      NAME="${1#--name=}"
      shift
      ;;
    --timeout)
      [ $# -ge 2 ] || { echo "--timeout requires a value" >&2; usage >&2; exit 1; }
      TIMEOUT="$2"
      shift 2
      ;;
    --timeout=*)
      TIMEOUT="${1#--timeout=}"
      shift
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

if [ -z "$NAME" ]; then
  echo "--name is required" >&2
  usage >&2
  exit 1
fi
case "$TIMEOUT" in
  ''|*[!0-9]*) echo "--timeout must be a whole number of seconds" >&2; exit 1 ;;
esac

# Prints the UDID of an available iOS device named $NAME, newest runtime first.
find_device() {
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin).get("devices", {})
def version(runtime):
    return [int(p) for p in runtime.rsplit("iOS-", 1)[1].split("-") if p.isdigit()]
for runtime in sorted((r for r in devices if ".SimRuntime.iOS-" in r), key=version, reverse=True):
    for device in devices[runtime]:
        if device.get("name") == name:
            print(device["udid"], runtime.rsplit(".", 1)[1])
            sys.exit(0)
' "$NAME"
}

deadline=$((SECONDS + TIMEOUT))
while :; do
  # simctl itself can fail while CoreSimulator is starting; that counts as "not yet".
  found="$(find_device || true)"
  if [ -n "$found" ]; then
    echo "Found simulator \"$NAME\": $found (after ${SECONDS}s)"
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::No available simulator named \"$NAME\" after ${TIMEOUT}s"
    xcrun simctl list devices available || true
    exit 1
  fi
  sleep 5
done
