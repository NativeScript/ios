#!/bin/bash
# CI-only: start booting an existing simulator in the background and print its
# UDID, so the boot overlaps dependency setup and the build. Pass the UDID to
# xcodebuild as `-destination id=<udid>`; xcodebuild waits for a device that is
# still booting.
set -euo pipefail

usage() {
  echo "Usage: ./scripts/boot-ci-simulator.sh --device <name> [--log <file>]"
  echo ""
  echo "  --device <name>  simulator name, e.g. 'iPhone 16 Pro'. Of the available"
  echo "                   devices with that name, the one on the newest iOS"
  echo "                   runtime is used (what xcodebuild picks for OS=latest)"
  echo "  --log <file>     where the background boot writes its output"
  echo "                   (default: \$RUNNER_TEMP or /tmp, simulator-boot.log)"
  echo "  -h, --help       show this help"
}

DEVICE=""
LOG="${RUNNER_TEMP:-/tmp}/simulator-boot.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --device)
      [ $# -ge 2 ] || { echo "--device needs a value" >&2; usage >&2; exit 1; }
      DEVICE="$2"
      shift 2
      ;;
    --log)
      [ $# -ge 2 ] || { echo "--log needs a value" >&2; usage >&2; exit 1; }
      LOG="$2"
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

if [ -z "$DEVICE" ]; then
  echo "--device is required" >&2
  usage >&2
  exit 1
fi

UDID=$(xcrun simctl list devices available --json | python3 -c "
import json, sys
name = sys.argv[1]

def vkey(runtime):
    return [int(p) for p in runtime.split('.')[-1].split('-') if p.isdigit()]

matches = [(vkey(runtime), d['udid'])
           for runtime, devices in json.load(sys.stdin)['devices'].items()
           if '.iOS-' in runtime
           for d in devices
           if d.get('isAvailable') and d['name'] == name]
if not matches:
    sys.exit(f'No available iOS simulator named \"{name}\".')
print(max(matches)[1])
" "$DEVICE")

echo "Booting $DEVICE ($UDID) in the background; log: $LOG" >&2
nohup xcrun simctl bootstatus "$UDID" -b >"$LOG" 2>&1 &
echo "$UDID"
