#!/bin/sh
set -eu

MACMON_LIB_DIR="../macmon/target/release"
SOURCE_LIB="$MACMON_LIB_DIR/libmacmon.dylib"
DEST_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
DEST_LIB="$DEST_DIR/libmacmon.dylib"

if [ ! -f "$SOURCE_LIB" ]; then
  echo "Missing macmon dylib: $SOURCE_LIB" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp -f "$SOURCE_LIB" "$DEST_LIB"

codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST_LIB"
