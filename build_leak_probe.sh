#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

# NativeScriptLeakProbe links NativeScript.framework, and is linked here against
# the slices build_nativescript.sh left in dist/NativeScript.xcframework: its
# scheme does not build the runtime again for every slice. Run that first.

function to_bool() {
  local arg="$1"
  case "$(echo "$arg" | tr '[:upper:]' '[:lower:]')" in
    n|no|f|false) echo false ;;
    y|yes|t|true) echo true ;;
    # case patterns are globs, not regexes: whatever gets past this arm is all digits
    ''|*[!0-9]*)
      if [ -n "$arg" ]; then
        echo "warning: invalid boolean argument ('$arg'). Expected true or false" >&2
      fi
      echo false
      ;;
    * )
      if [ "$arg" -eq 0 ]; then
        echo false
      else
        echo true
      fi
      ;;
  esac;
}

BUILD_CATALYST=$(to_bool ${BUILD_CATALYST:=true})
BUILD_IPHONE=$(to_bool ${BUILD_IPHONE:=true})
BUILD_SIMULATOR=$(to_bool ${BUILD_SIMULATOR:=true})
BUILD_VISION=$(to_bool ${BUILD_VISION:=true})
VERBOSE=$(to_bool ${VERBOSE:=false})

for arg in $@; do
  case $arg in
    --catalyst|--maccatalyst) BUILD_CATALYST=true ;;
    --no-catalyst|--no-maccatalyst) BUILD_CATALYST=false ;;
    --sim|--simulator) BUILD_SIMULATOR=true ;;
    --no-sim|--no-simulator) BUILD_SIMULATOR=false ;;
    --iphone|--device) BUILD_IPHONE=true ;;
    --no-iphone|--no-device) BUILD_IPHONE=false ;;
    --xr|--vision) BUILD_VISION=true ;;
    --no-xr|--no-vision) BUILD_VISION=false ;;
    --verbose|-v) VERBOSE=true ;;
    *) ;;
  esac
done

QUIET=
if ! $VERBOSE; then
  QUIET=-quiet
fi

DEV_TEAM=${DEVELOPMENT_TEAM:-}
DIST="$PWD/dist"
RUNTIME="$DIST/NativeScript.xcframework"
mkdir -p "$DIST/intermediates"

# runtime_slice <platform> <variant>: the runtime xcframework's slice directory,
# e.g. "ios" "simulator"; an empty variant is the device slice.
function runtime_slice() {
  local platform="$1" variant="$2" dir name
  for dir in "$RUNTIME"/"$platform"-*; do
    [ -d "$dir/NativeScript.framework" ] || continue
    name=$(basename "$dir")
    case "$name" in
      *-simulator|*-maccatalyst) [ "$name" = "${name%-$variant}" ] && continue ;;
      *) [ -n "$variant" ] && continue ;;
    esac
    echo "$dir"
    return
  done
  echo "Missing the $platform${variant:+ $variant} slice of $RUNTIME: run ./build_nativescript.sh first." >&2
  exit 1
}

# archive <name> <destination> <runtime slice> [build settings...]
function archive() {
  local name="$1" destination="$2" slice="$3"
  shift 3
  checkpoint "Building NativeScriptLeakProbe for $name"
  xcodebuild archive -project v8ios.xcodeproj \
                     -scheme NativeScriptLeakProbe \
                     -configuration Release \
                     -destination "$destination" \
                     $QUIET \
                     DEVELOPMENT_TEAM=$DEV_TEAM \
                     SKIP_INSTALL=NO \
                     BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                     FRAMEWORK_SEARCH_PATHS="$slice" \
                     "$@" \
                     -archivePath "$DIST/intermediates/NativeScriptLeakProbe.$name.xcarchive"
}

checkpoint "Cleanup NativeScriptLeakProbe"
xcodebuild -project v8ios.xcodeproj \
           -target NativeScriptLeakProbe \
           -configuration Release clean \
           $QUIET

# The architecture settings match build_nativescript.sh: a slice links against
# the runtime slice of the same architectures.
ARCHIVES=()
if $BUILD_SIMULATOR; then
  SLICE=$(runtime_slice ios simulator)
  archive iphonesimulator "generic/platform=iOS Simulator" "$SLICE" EXCLUDED_ARCHS="i386"
  ARCHIVES+=(iphonesimulator)
fi

if $BUILD_IPHONE; then
  SLICE=$(runtime_slice ios "")
  archive iphoneos "generic/platform=iOS" "$SLICE" EXCLUDED_ARCHS="armv7"
  ARCHIVES+=(iphoneos)
fi

if $BUILD_CATALYST; then
  SLICE=$(runtime_slice ios maccatalyst)
  archive maccatalyst "generic/platform=macOS,variant=Mac Catalyst" "$SLICE" EXCLUDED_ARCHS="x86_64"
  ARCHIVES+=(maccatalyst)
fi

if $BUILD_VISION; then
  SLICE=$(runtime_slice xros "")
  archive xros "generic/platform=visionOS" "$SLICE" EXCLUDED_ARCHS="i386 x86_64" VALID_ARCHS=arm64
  SLICE=$(runtime_slice xros simulator)
  archive xrsimulator "generic/platform=visionOS Simulator" "$SLICE" \
          EXCLUDED_ARCHS="i386 x86_64" VALID_ARCHS=arm64
  ARCHIVES+=(xros xrsimulator)
fi

XCFRAMEWORKS=()
for name in "${ARCHIVES[@]}"; do
  ARCHIVE="$DIST/intermediates/NativeScriptLeakProbe.$name.xcarchive"
  XCFRAMEWORKS+=( -framework "$ARCHIVE/Products/Library/Frameworks/NativeScriptLeakProbe.framework" \
                  -debug-symbols "$ARCHIVE/dSYMs/NativeScriptLeakProbe.framework.dSYM" )
done

checkpoint "Creating NativeScriptLeakProbe.xcframework"
OUTPUT_DIR="$DIST/NativeScriptLeakProbe.xcframework"
rm -rf "$OUTPUT_DIR"
xcodebuild -create-xcframework "${XCFRAMEWORKS[@]}" -output "$OUTPUT_DIR"

rm -rf "$DIST/intermediates"
