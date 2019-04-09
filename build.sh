#!/bin/bash

pushd v8

ARCH_ARR=(x64 arm64)
MODULES=(v8_base v8_libplatform v8_libbase v8_libsampler v8_external_snapshot v8_initializers v8_init torque_generated_initializers)

for CURRENT_ARCH in ${ARCH_ARR[@]}
do
    OUTFOLDER=outgn/$CURRENT_ARCH-release
    echo "Building for $OUTFOLDER"
    gn gen $OUTFOLDER --args="use_custom_libcxx=false symbol_level=0 v8_enable_v8_checks=false v8_enable_debugging_features=false is_debug=false v8_use_snapshot=true v8_use_external_startup_data=true use_xcode_clang=true enable_ios_bitcode=true v8_enable_i18n_support=false target_cpu=\"$CURRENT_ARCH\" v8_target_cpu=\"$CURRENT_ARCH\" target_os=\"ios\" ios_deployment_target=\"10.0\""
    ninja -C $OUTFOLDER ${MODULES[@]}

    for MODULE in ${MODULES[@]}
    do
        echo "Linking lib$MODULE.a"
        ar r $OUTFOLDER/obj/$MODULE/lib$MODULE.a $OUTFOLDER/obj/$MODULE/*.o
    done

    pushd $OUTFOLDER
    xxd -i natives_blob.bin > natives_blob.h
    xxd -i snapshot_blob.bin > snapshot_blob.h
    popd
done

echo "Creating fat libraries"
DIST="./dist"
mkdir -p $DIST
for MODULE in ${MODULES[@]}
do
    FAT_LIBRARY_OUTPUT="lipo"
    for CURRENT_ARCH in ${ARCH_ARR[@]}
    do
        OUTFOLDER=outgn/$CURRENT_ARCH-release
        FAT_LIBRARY_OUTPUT="$FAT_LIBRARY_OUTPUT $OUTFOLDER/obj/$MODULE/lib$MODULE.a"
    done
    FAT_LIBRARY_OUTPUT="$FAT_LIBRARY_OUTPUT -create -output $DIST/lib$MODULE.a"
    eval $FAT_LIBRARY_OUTPUT
done

popd
