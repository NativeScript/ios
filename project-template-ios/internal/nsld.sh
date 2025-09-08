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

# Resolve linker: prefer provided NS_LD, otherwise use toolchain clang if present.
DEFAULT_LD="$TOOLCHAIN_DIR/usr/bin/clang"
if [[ -z "$NS_LD" ]]; then
    if [[ -x "$DEFAULT_LD" ]]; then
        NS_LD="$DEFAULT_LD"
    else
        echo "NSLD: Skipping link because toolchain clang not found: $DEFAULT_LD (TOOLCHAIN_DIR may be missing)."
    fi
fi

# If NS_LD was explicitly set to the default path but it's missing, skip as well.
if [[ "$NS_LD" == "$DEFAULT_LD" && ! -x "$NS_LD" ]]; then
    echo "NSLD: Skipping link because toolchain clang not found: $NS_LD (TOOLCHAIN_DIR may be missing)."
else
  "$NS_LD" "$@"
fi
