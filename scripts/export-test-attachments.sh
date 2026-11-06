#!/bin/bash
# Export the attachments of an .xcresult bundle under their human-readable
# names. `xcresulttool export attachments` writes each file under a UUID with no
# extension and records the readable name in manifest.json; the junit reports
# are found by name (*junit*.xml), so this renames them.
set -euo pipefail

usage() {
  echo "Usage: ./scripts/export-test-attachments.sh --result <bundle.xcresult> --output <dir>"
  echo ""
  echo "  --result <path>  result bundle to read"
  echo "  --output <dir>   directory the attachments are written to (created if missing)"
  echo "  -h, --help       show this help"
}

RESULT=""
OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --result)
      [ $# -ge 2 ] || { echo "--result needs a value" >&2; usage >&2; exit 1; }
      RESULT="$2"
      shift 2
      ;;
    --output)
      [ $# -ge 2 ] || { echo "--output needs a value" >&2; usage >&2; exit 1; }
      OUTPUT="$2"
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

if [ -z "$RESULT" ] || [ -z "$OUTPUT" ]; then
  echo "--result and --output are required" >&2
  usage >&2
  exit 1
fi

mkdir -p "$OUTPUT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUTPUT"

python3 - "$OUTPUT" <<'PY'
import json, os, sys

out = sys.argv[1]
with open(os.path.join(out, "manifest.json")) as f:
    manifest = json.load(f)

for test in manifest:
    for a in test.get("attachments", []):
        src = os.path.join(out, a["exportedFileName"])
        name = os.path.basename(a.get("suggestedHumanReadableName") or a["exportedFileName"])
        dst = os.path.join(out, name)
        if os.path.exists(dst) and dst != src:
            stem, ext = os.path.splitext(name)
            dst = os.path.join(out, f"{stem}_{a['exportedFileName']}{ext}")
        if os.path.exists(src):
            os.rename(src, dst)
            print(f"{test.get('testIdentifier', '?')}: {os.path.basename(dst)}")
PY
