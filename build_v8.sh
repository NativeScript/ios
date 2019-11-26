#!/bin/bash
set -e

pushd v8

ARCH_ARR=(x64 arm64)
#MODULES=(v8_base_without_compiler v8_compiler v8_libplatform v8_libbase v8_libsampler v8_initializers v8_init v8_snapshot torque_generated_initializers torque_generated_definitions)
MODULES=(v8_base_without_compiler v8_compiler v8_libplatform v8_libbase v8_libsampler v8_initializers v8_init v8_snapshot torque_generated_initializers)

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    OUTFOLDER=out.gn/$CURRENT_ARCH-release
    echo "Building for $OUTFOLDER"
    gn gen $OUTFOLDER --args="v8_enable_pointer_compression=false is_official_build=true use_custom_libcxx=false is_component_build=false symbol_level=0 v8_enable_v8_checks=false v8_enable_debugging_features=false is_debug=false v8_use_external_startup_data=false use_xcode_clang=true enable_ios_bitcode=true v8_enable_i18n_support=false target_cpu=\"$CURRENT_ARCH\" v8_target_cpu=\"$CURRENT_ARCH\" target_os=\"ios\" ios_deployment_target=\"9.0\""
    #gn gen $OUTFOLDER --args="v8_enable_pointer_compression=false use_custom_libcxx=false is_component_build=false symbol_level=2 v8_enable_v8_checks=true v8_enable_debugging_features=true is_debug=true v8_use_external_startup_data=true use_xcode_clang=true enable_ios_bitcode=true v8_enable_i18n_support=false target_cpu=\"$CURRENT_ARCH\" v8_target_cpu=\"$CURRENT_ARCH\" target_os=\"ios\" ios_deployment_target=\"9.0\""
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
    ar r $OUTFOLDER/obj/third_party/inspector_protocol/libinspector_protocol.a $OUTFOLDER/obj/third_party/inspector_protocol/crdtp/*.o
    cp "$OUTFOLDER/obj/third_party/inspector_protocol/libinspector_protocol.a" "$DIST/$CURRENT_ARCH"

    ZLIB_INPUT="$OUTFOLDER/obj/third_party/zlib/zlib/*.o"
    if [ $CURRENT_ARCH = "arm64" ]; then
        ZLIB_INPUT="$ZLIB_INPUT $OUTFOLDER/obj/third_party/zlib/zlib_adler32_simd/*.o"
    fi

    ar r $OUTFOLDER/obj/third_party/zlib/libzip.a $ZLIB_INPUT
    cp "$OUTFOLDER/obj/third_party/zlib/libzip.a" "$DIST/$CURRENT_ARCH"
done

popd
