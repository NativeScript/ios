#!/bin/bash

set -e

pushd v8

ARCH_ARR=(x64 arm64)
MODULES=(v8_base_without_compiler v8_compiler v8_libplatform v8_libbase v8_libsampler v8_snapshot torque_generated_initializers torque_generated_definitions)

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    OUTFOLDER=out.gn/$CURRENT_ARCH-catalyst-release
    echo "Building for $OUTFOLDER"
    gn gen $OUTFOLDER --args="v8_enable_pointer_compression=false is_official_build=true use_custom_libcxx=false is_component_build=false symbol_level=0 v8_enable_v8_checks=false v8_enable_debugging_features=false is_debug=false v8_use_external_startup_data=false use_xcode_clang=true enable_ios_bitcode=true v8_enable_i18n_support=false target_environment=\"catalyst\" target_cpu=\"$CURRENT_ARCH\" v8_target_cpu=\"$CURRENT_ARCH\" target_os=\"ios\" ios_deployment_target=\"13.0\""
    ninja -C $OUTFOLDER ${MODULES[@]} inspector

    for MODULE in ${MODULES[@]}
    do
        ar r $OUTFOLDER/obj/$MODULE/lib$MODULE.a $OUTFOLDER/obj/$MODULE/*.o
    done
done

DIST="./dist"
mkdir -p $DIST
for MODULE in ${MODULES[@]}
do
    for CURRENT_ARCH in ${ARCH_ARR[@]}
    do
        mkdir -p "$DIST/$CURRENT_ARCH-catalyst"
        OUTFOLDER=out.gn/$CURRENT_ARCH-catalyst-release
        cp "$OUTFOLDER/obj/$MODULE/lib$MODULE.a" "$DIST/$CURRENT_ARCH-catalyst"
    done
done

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    mkdir -p "$DIST/$CURRENT_ARCH-catalyst"
    OUTFOLDER=out.gn/$CURRENT_ARCH-catalyst-release
    ar r $OUTFOLDER/obj/third_party/inspector_protocol/libinspector_protocol.a $OUTFOLDER/obj/third_party/inspector_protocol/crdtp/*.o $OUTFOLDER/obj/third_party/inspector_protocol/crdtp_platform/*.o
    cp "$OUTFOLDER/obj/third_party/inspector_protocol/libinspector_protocol.a" "$DIST/$CURRENT_ARCH-catalyst"

    ZLIB_INPUT="$OUTFOLDER/obj/third_party/zlib/zlib/*.o"
    if [ $CURRENT_ARCH = "arm64" ]; then
        ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/zlib_adler32_simd/*.o"
        ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/zlib_inflate_chunk_simd/*.o"
    fi

    ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/google/compression_utils_portable/*.o"

    ar r $OUTFOLDER/obj/third_party/zlib/libzip.a $ZLIB_INPUT
    cp "$OUTFOLDER/obj/third_party/zlib/libzip.a" "$DIST/$CURRENT_ARCH-catalyst"

    ar r $OUTFOLDER/obj/cppgc_base/libcppgc_base.a $OUTFOLDER/obj/cppgc_base/*.o
    cp "$OUTFOLDER/obj/cppgc_base/libcppgc_base.a" "$DIST/$CURRENT_ARCH-catalyst"

    ar r $OUTFOLDER/obj/v8_cppgc_shared/libv8_cppgc_shared.a $OUTFOLDER/obj/v8_cppgc_shared/*.o
    cp "$OUTFOLDER/obj/v8_cppgc_shared/libv8_cppgc_shared.a" "$DIST/$CURRENT_ARCH-catalyst"
done

popd

