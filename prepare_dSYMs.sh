#!/bin/bash
set -e

OUTFOLDER="./dist/dSYMs"

mkdir -p "$OUTFOLDER"

for framework_path in ./dist/NativeScript.xcframework/ios*; do
    DSYMPATH="$framework_path/dSYMs/NativeScript.framework.dSYM"
    if [ -d "$DSYMPATH" ]; then
        OUTPATH="$OUTFOLDER/$(basename $framework_path)NativeScript.framework.dSYM"
        echo "Copying $DSYMPATH to $OUTPATH"
        cp -r "$DSYMPATH" "$OUTPATH"
    fi
done

