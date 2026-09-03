#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR="$PLUGIN_DIR/runtime/macos"

mkdir -p "$OUTPUT_DIR"
xcrun swiftc \
  -O \
  -framework ApplicationServices \
  -framework AppKit \
  -framework Security \
  -framework SystemConfiguration \
  "$PLUGIN_DIR"/native/*.swift \
  -o "$OUTPUT_DIR/chatgpt-auto-confirm"

SIGN_IDENTITY=${CHATGPT_AUTO_CONFIRM_CODESIGN_IDENTITY:-}
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development:/ { print $2; exit }')
fi

if [ -n "$SIGN_IDENTITY" ]; then
  codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --identifier com.fabushi.chatgpt-auto-confirm.runtime \
    --timestamp=none \
    "$OUTPUT_DIR/chatgpt-auto-confirm"
else
  echo "warning: no Apple Development signing identity found; runtime remains ad-hoc signed" >&2
fi
