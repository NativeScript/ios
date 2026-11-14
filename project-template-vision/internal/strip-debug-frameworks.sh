#!/usr/bin/env bash

# Removes the frameworks listed in NS_DEBUG_FRAMEWORKS from the app in builds that
# don't define DEBUG, except those listed in NS_SHIP_DEBUG_FRAMEWORKS. Both settings
# take framework names separated by spaces or commas.
#
# nsld.sh weak-links these frameworks, so the app launches without them; code that
# uses one must look it up at runtime (see main.m).

set -e

if [[ " ${GCC_PREPROCESSOR_DEFINITIONS} " =~ [[:space:]]DEBUG(=|[[:space:]]) ]]; then
  exit 0
fi

SHIPPED=" ${NS_SHIP_DEBUG_FRAMEWORKS//,/ } "
FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

for NAME in ${NS_DEBUG_FRAMEWORKS//,/ }; do
  if [[ "$SHIPPED" == *" $NAME "* ]]; then
    echo "Keeping debug framework $NAME (NS_SHIP_DEBUG_FRAMEWORKS)"
  elif [ -d "$FRAMEWORKS_DIR/$NAME.framework" ]; then
    echo "Removing debug framework $NAME"
    rm -rf "$FRAMEWORKS_DIR/$NAME.framework"
  fi
done
