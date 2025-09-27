#!/usr/bin/env bash
source ./.build_env_vars.sh

MODULES_DIR="$SRCROOT/internal/Swift-Modules"

function DELETE_SWIFT_MODULES_DIR() {
    rm -rf "$MODULES_DIR"
}

function getArch() {
    while [[ $# -gt 0 ]]
    do
        case $1 in
            -arch)
                printf $2
                return
                ;;
            -target)
                printf `echo $2 | cut -f1 -d'-'`
                return
                ;;
        esac
        shift
    done
}

function GEN_MODULEMAP() {
    ARCH_ARG=$1
    SWIFT_HEADER_DIR=$PER_VARIANT_OBJECT_FILE_DIR/$ARCH_ARG

    DELETE_SWIFT_MODULES_DIR
    if [ -d "$SWIFT_HEADER_DIR" ]; then
        HEADER_PATH=$(find "$SWIFT_HEADER_DIR" -name '*-Swift.h' 2>/dev/null)
        if [ -n "$HEADER_PATH" ]; then
            mkdir -p "$MODULES_DIR"
            CONTENT="module nsswiftsupport { \n header \"$HEADER_PATH\" \n export * \n}"
            printf "$CONTENT" > "$MODULES_DIR/module.modulemap"
        else
            echo "NSLD: Swift bridging header '*-Swift.h' not found under '$SWIFT_HEADER_DIR'"
        fi
    else
        echo "NSLD: Directory for Swift headers ($SWIFT_HEADER_DIR) not found."
    fi
}

function GEN_METADATA() {
    TARGET_ARCH=$1
    set -e
    cpu_arch=$(uname -m)
    pushd "$SRCROOT/internal/metadata-generator-${cpu_arch}/bin"
    ./build-step-metadata-generator.py $TARGET_ARCH
    popd
}

# Workaround for ARCH being set to `undefined_arch` here. Extract it from command line arguments.
TARGET_ARCH=$(getArch "$@")
GEN_MODULEMAP $TARGET_ARCH
printf "Generating metadata..."
GEN_METADATA $TARGET_ARCH
DELETE_SWIFT_MODULES_DIR

function resolve_clang() {
    # 1) If NS_LD is set and executable, honor it.
    if [[ -n "$NS_LD" && -x "$NS_LD" ]]; then
        echo "$NS_LD"
        return 0
    fi

    # 2) TOOLCHAIN_DIR (if provided)
    if [[ -n "$TOOLCHAIN_DIR" && -x "$TOOLCHAIN_DIR/usr/bin/clang" ]]; then
        echo "$TOOLCHAIN_DIR/usr/bin/clang"
        return 0
    fi

    # 3) Xcode's DT_TOOLCHAIN_DIR (provided by xcodebuild)
    if [[ -n "$DT_TOOLCHAIN_DIR" && -x "$DT_TOOLCHAIN_DIR/usr/bin/clang" ]]; then
        echo "$DT_TOOLCHAIN_DIR/usr/bin/clang"
        return 0
    fi

    # 4) xcrun lookup (most reliable within Xcode build env)
    local xcrun_clang
    xcrun_clang=$(xcrun --find clang 2>/dev/null) || true
    if [[ -n "$xcrun_clang" && -x "$xcrun_clang" ]]; then
        echo "$xcrun_clang"
        return 0
    fi

    # 5) Xcode default toolchain from xcode-select
    local xcode_path
    xcode_path=$(xcode-select -p 2>/dev/null) || true
    if [[ -n "$xcode_path" && -x "$xcode_path/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]]; then
        echo "$xcode_path/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        return 0
    fi

    # 6) System fallback
    if [[ -x "/usr/bin/clang" ]]; then
        echo "/usr/bin/clang"
        return 0
    fi

    return 1
}

CLANG_PATH=$(resolve_clang)
if [[ -z "$CLANG_PATH" ]]; then
    echo "NSLD: ERROR: Could not locate a usable clang. TOOLCHAIN_DIR='${TOOLCHAIN_DIR}' DT_TOOLCHAIN_DIR='${DT_TOOLCHAIN_DIR}'."
    exit 1
fi

# For visibility downstream, set NS_LD to the resolved path and invoke.
NS_LD="$CLANG_PATH"
"$NS_LD" "$@"
