#!/bin/bash
# Build a local app bundle. --demo uses sample sessions and separate preferences.
set -euo pipefail
cd "$(dirname "$0")"

sessionhub_mode=release
sessionhub_name=SessionHub
sessionhub_demo=false
for sessionhub_arg in "$@"; do
    case "$sessionhub_arg" in
        --demo) sessionhub_demo=true; sessionhub_name=SessionHubDemo ;;
        --debug) sessionhub_mode=debug ;;
        *) echo "Usage: ./build.sh [--demo] [--debug]" >&2; exit 2 ;;
    esac
done

swift build -c "$sessionhub_mode"
sessionhub_bin=$(swift build -c "$sessionhub_mode" --show-bin-path)
mkdir -p build
sessionhub_package=$(mktemp -d build/.package.XXXXXX)
trap 'rm -rf "$sessionhub_package"' EXIT
sessionhub_bundle="$sessionhub_package/$sessionhub_name.app"
mkdir -p "$sessionhub_bundle/Contents/MacOS" "$sessionhub_bundle/Contents/Resources"
cp "$sessionhub_bin/SessionHub" "$sessionhub_bundle/Contents/MacOS/SessionHub"
cp Info.plist "$sessionhub_bundle/Contents/Info.plist"
if "$sessionhub_demo"; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.sessionhub.demo' "$sessionhub_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName SessionHubDemo' "$sessionhub_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName SessionHub Demo' "$sessionhub_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SessionHubDemo bool true' "$sessionhub_bundle/Contents/Info.plist"
fi
codesign --force --sign "${SESSIONHUB_SIGNING_IDENTITY:--}" "$sessionhub_bundle"
codesign --verify --deep --strict "$sessionhub_bundle"
rm -rf "build/$sessionhub_name.app"
mv "$sessionhub_bundle" "build/$sessionhub_name.app"
printf '\nBuilt and verified: build/%s.app\n' "$sessionhub_name"
