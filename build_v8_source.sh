#!/bin/bash
set -e

pushd v8

ARCH_ARR=(x64-simulator arm64-simulator arm64-device)
MODULES=(v8_base_without_compiler v8_compiler v8_libplatform v8_libbase v8_bigint v8_snapshot v8_heap_base v8_heap_base_headers torque_generated_initializers torque_generated_definitions)

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    OUTFOLDER=out.gn/$CURRENT_ARCH-release
    ARCH_PARTS=(${CURRENT_ARCH//-/ })
    TARGET_ENV=${ARCH_PARTS[1]}
    echo "Building for $OUTFOLDER ($TARGET_ENV)"
    ARCH=${ARCH_PARTS[0]}
    gn gen $OUTFOLDER --args="v8_enable_webassembly=false treat_warnings_as_errors=false v8_enable_pointer_compression=false is_official_build=true use_custom_libcxx=false is_component_build=false symbol_level=0 v8_enable_v8_checks=false v8_enable_debugging_features=false is_debug=false v8_use_external_startup_data=false use_xcode_clang=true enable_ios_bitcode=true v8_enable_i18n_support=false target_environment=\"$TARGET_ENV\" target_cpu=\"$ARCH\" v8_target_cpu=\"$ARCH\" target_os=\"ios\" ios_deployment_target=\"9.0\""
    ninja -C $OUTFOLDER ${MODULES[@]} inspector

    for MODULE in ${MODULES[@]}
    do
        ar r $OUTFOLDER/obj/$MODULE/lib$MODULE.a $OUTFOLDER/obj/$MODULE/*.o
    done

    # Those libraries are needed if we set v8_enable_i18n_support=true
    # See https://groups.google.com/forum/#!topic/v8-users/T3Cye9FHRQk for embedding the icudtl.dat into the application
    # OBJECTS="$OBJECTS $OUTFOLDER/obj/third_party/icu/icuuc/*.o"
    # OBJECTS="$OBJECTS $OUTFOLDER/obj/third_party/icu/icui18n/*.o"
    # OBJECTS="$OBJECTS $OUTFOLDER/obj/v8_crash_keys/*.o"

    # ar r $OUTFOLDER/libv8.a $OBJECTS
done

DIST="./dist"
mkdir -p $DIST
for MODULE in ${MODULES[@]}
do
    for CURRENT_ARCH in ${ARCH_ARR[@]}
    do
	mkdir -p "$DIST/$CURRENT_ARCH"
        OUTFOLDER=out.gn/$CURRENT_ARCH-release
        cp "$OUTFOLDER/obj/$MODULE/lib$MODULE.a" "$DIST/$CURRENT_ARCH"
    done
done

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    mkdir -p "$DIST/$CURRENT_ARCH"
    OUTFOLDER=out.gn/$CURRENT_ARCH-release
    ar r $OUTFOLDER/obj/third_party/inspector_protocol/libinspector_protocol.a $OUTFOLDER/obj/third_party/inspector_protocol/crdtp/*.o $OUTFOLDER/obj/third_party/inspector_protocol/crdtp_platform/*.o
    cp "$OUTFOLDER/obj/third_party/inspector_protocol/libinspector_protocol.a" "$DIST/$CURRENT_ARCH"

    ZLIB_INPUT="$OUTFOLDER/obj/third_party/zlib/zlib/*.o"
    ARCH_PARTS=(${CURRENT_ARCH//-/ })
    ARCH=${ARCH_PARTS[0]}
    if [ $ARCH = "arm64" ]; then
        ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/zlib_adler32_simd/*.o"
        ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/zlib_inflate_chunk_simd/*.o"
    fi

    ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/google/compression_utils_portable/*.o"

    ar r $OUTFOLDER/obj/third_party/zlib/libzip.a $ZLIB_INPUT
    cp "$OUTFOLDER/obj/third_party/zlib/libzip.a" "$DIST/$CURRENT_ARCH"

    ar r $OUTFOLDER/obj/cppgc_base/libcppgc_base.a $OUTFOLDER/obj/cppgc_base/*.o
    cp "$OUTFOLDER/obj/cppgc_base/libcppgc_base.a" "$DIST/$CURRENT_ARCH"

    ar r $OUTFOLDER/obj/v8_cppgc_shared/libv8_cppgc_shared.a $OUTFOLDER/obj/v8_cppgc_shared/*.o
    cp "$OUTFOLDER/obj/v8_cppgc_shared/libv8_cppgc_shared.a" "$DIST/$CURRENT_ARCH"

    cp "$OUTFOLDER/obj/src/inspector/libinspector.a" "$DIST/$CURRENT_ARCH"
    cp "$OUTFOLDER/obj/src/inspector/libinspector_string_conversions.a" "$DIST/$CURRENT_ARCH"
done

popd
