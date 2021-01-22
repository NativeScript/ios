#!/bin/bash

set -e

pushd v8

ARCH_ARR=(x64)
MODULES=(v8_base_without_compiler v8_compiler v8_libplatform v8_libbase v8_libsampler v8_snapshot torque_generated_initializers)

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    OUTFOLDER=out.gn/$CURRENT_ARCH-catalyst-release
    echo "Building for $OUTFOLDER"
    gn gen $OUTFOLDER --args="v8_enable_pointer_compression=false is_official_build=true use_custom_libcxx=false is_component_build=false symbol_level=0 v8_enable_v8_checks=false v8_enable_debugging_features=false is_debug=false v8_use_external_startup_data=false use_xcode_clang=true enable_ios_bitcode=true v8_enable_i18n_support=false target_cpu=\"$CURRENT_ARCH\" v8_target_cpu=\"$CURRENT_ARCH\" target_os=\"ios\" ios_deployment_target=\"9.0\""
    ninja -v -C $OUTFOLDER ${MODULES[@]} inspector

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
done

popd


# gn gen out.gn/x64-catalyst-release --args="sysroot=\"/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk\" v8_enable_pointer_compression=false is_official_build=true use_custom_libcxx=false is_component_build=false symbol_level=0 v8_enable_v8_checks=false v8_enable_debugging_features=false is_debug=false v8_use_external_startup_data=false v8_enable_i18n_support=false use_xcode_clang=true enable_ios_bitcode=true target_cpu=\"x64\" v8_target_cpu=\"x64\" target_os=\"ios\""

# ninja -v -C out.gn/x64-catalyst-release v8_base_without_compiler v8_compiler v8_libplatform v8_libbase v8_libsampler v8_snapshot torque_generated_initializers inspector


# ar r out.gn/x64-catalyst-release/obj/v8_base_without_compiler/libv8_base_without_compiler.a out.gn/x64-catalyst-release/obj/v8_base_without_compiler/*.o
# ar r out.gn/x64-catalyst-release/obj/v8_compiler/libv8_compiler.a out.gn/x64-catalyst-release/obj/v8_compiler/*.o
# ar r out.gn/x64-catalyst-release/obj/v8_snapshot/libv8_snapshot.a out.gn/x64-catalyst-release/obj/v8_snapshot/*.o
# ar r out.gn/x64-catalyst-release/obj/v8_libbase/libv8_libbase.a out.gn/x64-catalyst-release/obj/v8_libbase/*.o
# ar r out.gn/x64-catalyst-release/obj/v8_libplatform/libv8_libplatform.a out.gn/x64-catalyst-release/obj/v8_libplatform/*.o
# ar r out.gn/x64-catalyst-release/obj/v8_libsampler/libv8_libsampler.a out.gn/x64-catalyst-release/obj/v8_libsampler/*.o
# ar r out.gn/x64-catalyst-release/obj/torque_generated_initializers/libtorque_generated_initializers.a out.gn/x64-catalyst-release/obj/torque_generated_initializers/*.o
# ar r out.gn/x64-catalyst-release/obj/third_party/inspector_protocol/libinspector_protocol.a out.gn/x64-catalyst-release/obj/third_party/inspector_protocol/crdtp/*.o out.gn/x64-catalyst-release/obj/third_party/inspector_protocol/crdtp_platform/*.o
# ar r out.gn/x64-catalyst-release/obj/third_party/zlib/libzip.a out.gn/x64-catalyst-release/obj/third_party/zlib/zlib/*.o out.gn/x64-catalyst-release/obj/third_party/zlib/google/compression_utils_portable/*.o

