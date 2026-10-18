#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
destination='generic/platform=iOS Simulator'
platform=simulator
configuration=Debug
signing=(CODE_SIGN_IDENTITY=-)
actions=(build)
for argument in "$@"; do
    case "$argument" in
        --device)
            destination='generic/platform=iOS'
            platform=device
            : "${DEVELOPMENT_TEAM:?Für den Gerätebuild DEVELOPMENT_TEAM setzen.}"
            signing=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
            ;;
        --release) configuration=Release ;;
        --clean) actions=(clean build) ;;
        *) echo "Aufruf: iOS/build.sh [--device] [--release] [--clean]" >&2; exit 2 ;;
    esac
done
xcodebuild -project "$root/iOS/StillePostMobile.xcodeproj" -scheme StillePostMobile \
    -configuration "$configuration" -destination "$destination" \
    -derivedDataPath "$root/build/iOS-$configuration-$platform" \
    "MARKETING_VERSION=$(cat "$root/VERSION")" "${signing[@]}" "${actions[@]}"
bundle="$root/build/iOS-$configuration-$platform/Build/Products/$configuration-iphoneos/StillePostMobile.app"
if [ "$platform" = simulator ]; then
    bundle="$root/build/iOS-$configuration-$platform/Build/Products/$configuration-iphonesimulator/StillePostMobile.app"
fi
if ! codesign --verify --deep --strict "$bundle"; then
    echo "Bundle-Signatur ungültig. Erneut mit --clean bauen." >&2
    exit 1
fi
