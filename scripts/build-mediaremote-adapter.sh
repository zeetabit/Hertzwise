#!/bin/sh
# Builds mediaremote-adapter from the pinned submodule into the app bundle:
# MediaRemoteAdapter.framework in Contents/Frameworks and the Perl launcher in
# Contents/Resources. Run from an Xcode build phase; it reads Xcode's settings.
set -eu

SRC="$SRCROOT/Vendor/mediaremote-adapter"
if [ ! -f "$SRC/CMakeLists.txt" ]; then
    echo "error: Vendor/mediaremote-adapter is empty. Run: git submodule update --init" >&2
    exit 1
fi

FRAMEWORK="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/MediaRemoteAdapter.framework"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
VERSION=$(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)

# The adapter's own source list, so a new release that adds files builds as is.
SOURCES=$(awk '/set\(ADAPTER_SOURCES/ { listing = 1; next }
               listing && /\)/ { print; listing = 0 }
               listing' "$SRC/CMakeLists.txt" \
          | grep -oE 'src/[A-Za-z0-9/_]+\.m' | sed "s#^#$SRC/#")

ARCH_FLAGS=""
for arch in $ARCHS; do
    ARCH_FLAGS="$ARCH_FLAGS -arch $arch"
done

rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/Versions/A/Resources" "$RESOURCES"

# shellcheck disable=SC2086 # word splitting of the flag and source lists is intended
xcrun clang -fobjc-arc -fvisibility=default -dynamiclib $ARCH_FLAGS \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$SRC/include" -I"$SRC/src" $SOURCES \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter"

cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key><string>$PRODUCT_BUNDLE_IDENTIFIER.MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
</dict>
</plist>
PLIST

ln -sfn A "$FRAMEWORK/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FRAMEWORK/Resources"

cp "$SRC/bin/mediaremote-adapter.pl" "$RESOURCES/mediaremote-adapter.pl"

codesign --force --timestamp=none --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$FRAMEWORK"
