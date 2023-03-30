#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

pushd v8

ARCH_ARR=(x64-simulator arm64-simulator arm64-device)
MODULES=(
    cppgc_base
    torque_generated_definitions
    torque_generated_initializers
    v8_base_without_compiler
    v8_bigint
    v8_compiler
    v8_heap_base
    v8_heap_base_headers
    v8_libbase
    v8_libplatform
    v8_snapshot
)
GN_ARGS_BASE="
    treat_warnings_as_errors=false

    icu_use_data_file=false
    use_custom_libcxx=false
    use_xcode_clang=true

    is_component_build=false
    is_debug=false

    enable_ios_bitcode=false
    ios_deployment_target=12
    ios_enable_code_signing=false
    target_os=\"ios\"

    v8_control_flow_integrity=false
    v8_monolithic=true
    v8_static_library=true
    v8_use_external_startup_data=false

    v8_enable_sandbox=false
    v8_enable_debugging_features=false
    v8_enable_i18n_support=false
    v8_enable_lite_mode=true
    v8_enable_pointer_compression=false
    v8_enable_v8_checks=false
    v8_enable_webassembly=false

    # Avoid linker errors relating to missing glibc_sin/cos
    v8_use_libm_trig_functions=false

"
# is_official_build=true
# clang_base_path=\"/Applications/Xcode-14.2.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr\"

# GN_ARGS_BASE = "$GN_ARGS_BASE v8_embedder_string=\"-nativescript\""

DIST="../v8_build"
mkdir -p $DIST


function archiveLib() {
    MODULE=$1
    OBJECTS=$2
    ARCH=$3
    MODULE_DEST=$DIST/$ARCH/_lib/$MODULE.a
    checkpoint "Archiving $MODULE"
    echo "MODULE= $MODULE"
    echo "OBJECTS= $OBJECTS"
    echo "ARCH= $ARCH"
    echo "MODULE_DEST= $MODULE_DEST"
    ar r $MODULE_DEST $OBJECTS || echo "Failed to archive $MODULE..."
    echo ""
    echo "Archiving $MODULE done."

    checkpoint "Stripping $MODULE"
    strip $MODULE_DEST || echo "Failed to strip $MODULE..."
}

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    mkdir -p "$DIST/$CURRENT_ARCH/_lib"
    OUTFOLDER=out.gn/$CURRENT_ARCH-release
    ARCH_PARTS=(${CURRENT_ARCH//-/ })
    TARGET_ENV=${ARCH_PARTS[1]}
    checkpoint "Building V8 for $OUTFOLDER ($TARGET_ENV)"
    ARCH=${ARCH_PARTS[0]}
    # gn args --list $OUTFOLDER
    gn gen $OUTFOLDER --args="${GN_ARGS_BASE} target_environment=\"$TARGET_ENV\" target_cpu=\"$ARCH\" v8_target_cpu=\"$ARCH\""
    # exit 0;
    echo "Started building v8: $(date)"
    ninja $@ -C $OUTFOLDER ${MODULES[@]} inspector
    echo "Finished building v8: $(date)"

    for MODULE in ${MODULES[@]}
    do
        archiveLib "lib$MODULE" "$OUTFOLDER/obj/$MODULE/*.o" $CURRENT_ARCH
    done

    # Those libraries are needed if we set v8_enable_i18n_support=true
    # See https://groups.google.com/forum/#!topic/v8-users/T3Cye9FHRQk for embedding the icudtl.dat into the application
    # OBJECTS="$OBJECTS $OUTFOLDER/obj/third_party/icu/icuuc/*.o"
    # OBJECTS="$OBJECTS $OUTFOLDER/obj/third_party/icu/icui18n/*.o"
    # OBJECTS="$OBJECTS $OUTFOLDER/obj/v8_crash_keys/*.o"

    # archiveLib "libv8" "$OBJECTS" $CURRENT_ARCH
done

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    checkpoint "Packaging libraries for $CURRENT_ARCH..."

    ARCH_PARTS=(${CURRENT_ARCH//-/ })
    ARCH=${ARCH_PARTS[0]}
    
    mkdir -p "$DIST/$CURRENT_ARCH"
    OUTFOLDER=out.gn/$CURRENT_ARCH-release
    
    ZLIB_INPUT="$OUTFOLDER/obj/third_party/zlib/zlib/*.o"

    if [ $ARCH = "arm64" ]; then
        ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/zlib_adler32_simd/*.o"
        ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/zlib_inflate_chunk_simd/*.o"
    fi

    ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/google/compression_utils_portable/*.o"

    archiveLib "libzip" "$ZLIB_INPUT" $CURRENT_ARCH
    archiveLib "libcrdtp" "$OUTFOLDER/obj/third_party/inspector_protocol/crdtp/*.o" $CURRENT_ARCH
    archiveLib "libcrdtp_platform" "$OUTFOLDER/obj/third_party/inspector_protocol/crdtp_platform/*.o" $CURRENT_ARCH
    archiveLib "libcppgc_base" "$OUTFOLDER/obj/cppgc_base/*.o" $CURRENT_ARCH

    checkpoint "Copying libinspector and libinspector_string_conversions"
    cp "$OUTFOLDER/obj/src/inspector/libinspector.a" "$DIST/$CURRENT_ARCH/_lib" || echo "Skip"
    cp "$OUTFOLDER/obj/src/inspector/libinspector_string_conversions.a" "$DIST/$CURRENT_ARCH/_lib" || echo "Skip"
done

popd
