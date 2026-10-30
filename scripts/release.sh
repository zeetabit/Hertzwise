#!/bin/bash
# Builds a release .dmg from a git ref, signed with the "Hertzwise" code-signing
# identity from the keychain. One stable identity keeps the app's designated
# requirement the same across releases, so macOS keeps the user's permissions
# (audio capture, Apple Music) after an update; an ad-hoc signature changes
# with every build and macOS asks again.
#
# Usage: scripts/release.sh [ref]   (default: main)
# Writes build/release/Hertzwise-<version>.dmg and prints its SHA-256.
set -euo pipefail

ref="${1:-main}"
identity="${HERTZWISE_SIGNING_IDENTITY:-Hertzwise}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/build/release"
work="$(mktemp -d)"
trap 'git -C "$repo" worktree remove --force "$work/src" 2>/dev/null || true; rm -rf "$work"' EXIT

# A clean checkout of the ref: nothing local or untracked reaches the release.
git -C "$repo" worktree add --quiet --detach "$work/src" "$ref"
git -C "$work/src" submodule update --init --quiet

xcodebuild -project "$work/src/SampleRateSwitcher.xcodeproj" -scheme SampleRateSwitcher \
    -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$work/dd" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO -quiet build

app="$work/dd/Build/Products/Release/Hertzwise.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"

# Inside out: the embedded framework, then the app with the project's entitlements.
for framework in "$app"/Contents/Frameworks/*.framework; do
    codesign --force --sign "$identity" --options runtime --timestamp=none "$framework"
done
codesign --force --sign "$identity" --options runtime --timestamp=none \
    --entitlements "$work/src/SampleRateSwitcher.entitlements" "$app"
codesign --verify --deep --strict "$app"
if codesign -d --entitlements :- "$app" 2>/dev/null | grep -q get-task-allow; then
    echo "error: the app carries the debug entitlement get-task-allow" >&2
    exit 1
fi

mkdir -p "$out" "$work/stage"
ditto "$app" "$work/stage/Hertzwise.app"
ln -s /Applications "$work/stage/Applications"
dmg="$out/Hertzwise-$version.dmg"
hdiutil create -quiet -volname "Hertzwise $version" -srcfolder "$work/stage" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify -quiet "$dmg"

codesign -d -r- "$app" 2>&1 | grep designated
shasum -a 256 "$dmg"
