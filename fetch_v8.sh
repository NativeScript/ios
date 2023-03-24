#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

V8_VERSION="10.3.22"

GCLIENT_SYNC_ARGS="
    --deps=ios 
    --reset
    --with_branch_head
    --revision $V8_VERSION
    --delete_unversioned_trees
"

checkpoint "Fetching V8 Version: $V8_VERSION"

echo running: gclient config --name v8 --unmanaged "https://chromium.googlesource.com/v8/v8.git"
gclient config --name v8 --unmanaged "https://chromium.googlesource.com/v8/v8.git"

checkpoint "Syncing V8"
echo running: gclient sync ${GCLIENT_SYNC_ARGS}
gclient sync ${GCLIENT_SYNC_ARGS}

checkpoint "Patching V8"

V8_PATCHSET_IOS=(
  # Fix use_system_xcode build error
  "system_xcode_build_error.patch"

  # Find libclang_rt.iossim.a on Xcode 14
  "v8_build_xcode14_toolchain_fixes.patch"
)

for patch in "${V8_PATCHSET_IOS[@]}"
do
    checkpoint "Patch set: ${patch}"
    patch -d "v8" -p1 < "v8_patches/$patch"
done