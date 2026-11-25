#!/bin/sh
set -eu

build=$(/usr/bin/git -C "$SRCROOT" rev-list --count HEAD)
/usr/bin/plutil -replace CFBundleVersion -string "$build" -o "$SCRIPT_OUTPUT_FILE_0" "$SCRIPT_INPUT_FILE_0"
if [ "$PRODUCT_TYPE" = com.apple.product-type.application ] && [ "$PLATFORM_NAME" != macosx ]; then
    /usr/bin/plutil -insert UILaunchScreen -dictionary "$SCRIPT_OUTPUT_FILE_0"
    /usr/bin/plutil -insert LSRequiresIPhoneOS -bool YES "$SCRIPT_OUTPUT_FILE_0"
fi
