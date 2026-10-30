#!/bin/bash
# Builds a release .dmg from a git ref, signed with the "Hertzwise" code-signing
# identity from the keychain. One stable identity keeps the app's designated
# requirement the same across releases, so macOS keeps the user's permissions
# (audio capture, Apple Music) after an update; an ad-hoc signature changes
# with every build and macOS asks again.
#
# It also writes the Sparkle appcast for that .dmg, signed with the Sparkle
# EdDSA key: from SPARKLE_ED_PRIVATE_KEY when set (CI), otherwise from the
# keychain account "hertzwise". The release notes are the ref's annotated tag
# message, when it has one.
#
# Usage: scripts/release.sh [ref]   (default: main)
# Writes build/release/Hertzwise-<version>.dmg and appcast.xml, and prints the
# .dmg's SHA-256.
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

sign() {
    codesign --force --sign "$identity" --options runtime --timestamp=none "$@"
}

# Inside out: each framework's helpers (Sparkle's XPC services, Autoupdate and
# Updater.app, keeping their own entitlements), the framework, then the app
# with the project's entitlements. Sparkle checks these signatures match
# before it installs an update.
for framework in "$app"/Contents/Frameworks/*.framework; do
    for helper in "$framework"/Versions/*/XPCServices/*.xpc "$framework"/Versions/*/Autoupdate \
                  "$framework"/Versions/*/*.app; do
        [ -e "$helper" ] && sign --preserve-metadata=entitlements "$helper"
    done
    sign "$framework"
done
# A self-signed identity has no Team ID, so library validation would refuse
# the app's own frameworks ("different Team IDs") and it would quit at
# launch. Release builds therefore opt out of library validation; the
# hardened runtime still blocks DYLD environment variables. Builds signed
# with a team keep it.
cp "$work/src/SampleRateSwitcher.entitlements" "$work/release.entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
    "$work/release.entitlements"
sign --entitlements "$work/release.entitlements" "$app"
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

# The appcast for this release: Sparkle signs the .dmg with the EdDSA key.
mkdir "$work/appcast"
cp "$dmg" "$work/appcast/"
notes="$(git -C "$repo" tag -l --format='%(contents)' "$ref")"
if [ -n "$notes" ]; then
    escaped="$(printf '%s' "$notes" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
    printf '<pre style="font: 13px -apple-system, sans-serif; white-space: pre-wrap">%s</pre>\n' "$escaped" \
        > "$work/appcast/Hertzwise-$version.html"
fi
generate_appcast="$work/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
appcast_args=(--download-url-prefix "https://github.com/zeetabit/Hertzwise/releases/download/v$version/"
              --embed-release-notes -o "$out/appcast.xml")
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$generate_appcast" --ed-key-file - "${appcast_args[@]}" "$work/appcast"
else
    "$generate_appcast" --account hertzwise "${appcast_args[@]}" "$work/appcast"
fi

codesign -d -r- "$app" 2>&1 | grep designated
shasum -a 256 "$dmg"
