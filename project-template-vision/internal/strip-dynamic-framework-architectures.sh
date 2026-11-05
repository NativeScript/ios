#!/usr/bin/env bash

################################################################################
#
# Copyright 2015 Realm Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

# This script strips all non-valid architectures from dynamic libraries in
# the application's `Frameworks` directory.
#
# The following environment variables are required:
#
# BUILT_PRODUCTS_DIR
# FRAMEWORKS_FOLDER_PATH
# VALID_ARCHS
# EXPANDED_CODE_SIGN_IDENTITY


# Signs a framework with the provided identity
code_sign() {
  # Use the current code_sign_identitiy
  echo "Code Signing $1 with Identity ${EXPANDED_CODE_SIGN_IDENTITY_NAME}"
  echo "/usr/bin/codesign --force --sign ${EXPANDED_CODE_SIGN_IDENTITY} --preserve-metadata=identifier,entitlements $1"
  /usr/bin/codesign --force --sign ${EXPANDED_CODE_SIGN_IDENTITY} --preserve-metadata=identifier,entitlements "$1"
}

if [ ! -e "${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}" ]; then
  exit 0
fi

# Simulator builds never ship, so extra architectures in them are harmless.
if [[ "${PLATFORM_NAME}" == *simulator ]]; then
  exit 0
fi

cd "${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"

shopt -s nullglob
for file in *.framework/* *.dylib; do
  # Only a framework's main binary (named after it) and loose dylibs are Mach-O
  if [[ "$file" == *.framework/* && "$(basename "$file")" != "$(basename "$(dirname "$file")" .framework)" ]]; then
    continue
  fi

  archs="$(lipo -archs "$file" 2>/dev/null)" || continue
  stripped=""
  for arch in $archs; do
    if ! [[ "${VALID_ARCHS}" == *"$arch"* ]]; then
      # Strip non-valid architectures in-place
      lipo -remove "$arch" -output "$file" "$file" || exit 1
      stripped="$stripped $arch"
    fi
  done

  if [[ "$stripped" != "" ]]; then
    echo "Stripped $file of architectures:$stripped"
    if [ "${CODE_SIGNING_ALLOWED}" == "YES" ]; then
      code_sign "${file}"
    fi
  fi
done
