#!/usr/bin/env bash

# Xcode embeds only the NS_DEBUG_FRAMEWORKS that INCLUDED_SOURCE_FILE_NAMES lists, but it
# never deletes the copy an earlier build left in the app.

set -e

INCLUDED=" ${INCLUDED_SOURCE_FILE_NAMES} "

for FRAMEWORK in ${NS_DEBUG_FRAMEWORKS}; do
  if [[ "$INCLUDED" != *" $FRAMEWORK "* ]]; then
    rm -rf "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${FRAMEWORK}"
  fi
done
