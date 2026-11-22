#!/usr/bin/env bash
set -euo pipefail

# Checks that a built .app carries no part of NativeScriptDevTunnel.framework:
# not the framework, and no relay string or symbol in any Mach-O file of the
# bundle. Then lists what of the dev tunnel the runtime binary keeps (the
# connector: the hook symbol name, its messages and its own symbols).

usage() {
  cat <<EOF
Usage: $0 <path/to/App.app>

Fails (exit 1) when the app embeds NativeScriptDevTunnel.framework or any
Mach-O file in it contains a relay string or symbol. A weak load command for
the framework in the app executable is reported, not failed: the app templates
weak-link every NS_DEBUG_FRAMEWORKS entry in all configurations, and dyld
skips it when the framework is absent.

  -h, --help   Show this help
EOF
}

APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$APP" ]; then
        echo "Only one app path is accepted." >&2
        usage >&2
        exit 2
      fi
      APP="$1"
      ;;
  esac
  shift
done

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "Missing or invalid app path." >&2
  usage >&2
  exit 2
fi

# Text only the relay writes or sends; the connector in the runtime has none.
RELAY_STRINGS=(
  "NSDT/1"
  "NativeScript dev tunnel listening for"
  "NativeScript.Debug.TunnelRequest"
)
RELAY_SYMBOL_PATTERN='nsdt_|_NativeScriptDevTunnelConnect$'

FAILED=0
fail() {
  echo "FAIL: $*"
  FAILED=1
}

FRAMEWORK_DIRS=()
while IFS= read -r -d '' dir; do
  FRAMEWORK_DIRS+=("$dir")
done < <(find "$APP" -type d -name "NativeScriptDevTunnel.framework" -print0)
for dir in ${FRAMEWORK_DIRS[@]+"${FRAMEWORK_DIRS[@]}"}; do
  fail "embeds ${dir#"$APP"/}"
done

MACHO_FILES=()
while IFS= read -r -d '' file; do
  if file -b "$file" | grep "Mach-O" >/dev/null; then
    MACHO_FILES+=("$file")
  fi
done < <(find "$APP" -type f -print0)

if [ "${#MACHO_FILES[@]}" -eq 0 ]; then
  echo "No Mach-O files found in $APP." >&2
  exit 2
fi

for file in "${MACHO_FILES[@]}"; do
  relative="${file#"$APP"/}"
  case "$relative" in
    */NativeScriptDevTunnel.framework/*) continue ;;
  esac
  for text in "${RELAY_STRINGS[@]}"; do
    if strings -a "$file" | grep -F -- "$text" >/dev/null; then
      fail "$relative contains \"$text\""
    fi
  done
  symbols="$(nm -a "$file" 2>/dev/null | grep -E -- "$RELAY_SYMBOL_PATTERN" | grep -v " U " || true)"
  if [ -n "$symbols" ]; then
    fail "$relative defines relay symbols:"
    printf '    %s\n' "$symbols"
  fi
  if otool -l "$file" | grep -A2 -E "LC_(LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD)_DYLIB" | grep "NativeScriptDevTunnel.framework" >/dev/null; then
    if otool -l "$file" | grep -A2 "LC_LOAD_WEAK_DYLIB" | grep "NativeScriptDevTunnel.framework" >/dev/null; then
      echo "note: $relative weak-links NativeScriptDevTunnel.framework (NS_DEBUG_FRAMEWORKS; dyld skips it when absent)"
    else
      fail "$relative links NativeScriptDevTunnel.framework strongly; the app cannot launch without it"
    fi
  fi
done

RUNTIME=""
for candidate in "$APP/Frameworks/NativeScript.framework/NativeScript" \
                 "$APP/Contents/Frameworks/NativeScript.framework/NativeScript"; do
  if [ -f "$candidate" ]; then
    RUNTIME="$candidate"
    break
  fi
done

echo ""
if [ -n "$RUNTIME" ]; then
  echo "Dev tunnel residue in ${RUNTIME#"$APP"/} (the connector, expected):"
  echo "  strings:"
  strings -a "$RUNTIME" | grep -i -E "devtunnel|dev tunnel" | sed 's/^/    /' || echo "    (none)"
  echo "  exported symbols:"
  nm -gU "$RUNTIME" 2>/dev/null | grep -i "devtunnel" | sed 's/^/    /' || echo "    (none)"
else
  echo "NativeScript.framework not found in $APP; nothing to list."
fi

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "Dev tunnel exclusion check FAILED for $APP"
  exit 1
fi
echo "Dev tunnel exclusion check passed for $APP (${#MACHO_FILES[@]} Mach-O files scanned)"
