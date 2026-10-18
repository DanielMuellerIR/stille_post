#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
destination='generic/platform=iOS Simulator'
platform=simulator
configuration=Debug
signing=(CODE_SIGN_IDENTITY=-)
for argument in "$@"; do
    case "$argument" in
        --device)
            destination='generic/platform=iOS'
            platform=device
            : "${DEVELOPMENT_TEAM:?Für den Gerätebuild DEVELOPMENT_TEAM setzen.}"
            signing=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
            ;;
        --release) configuration=Release ;;
        *) echo "Aufruf: iOS/build.sh [--device] [--release]" >&2; exit 2 ;;
    esac
done
exec xcodebuild -project "$root/iOS/StillePostMobile.xcodeproj" -scheme StillePostMobile \
    -configuration "$configuration" -destination "$destination" \
    -derivedDataPath "$root/build/iOS-$configuration-$platform" \
    "MARKETING_VERSION=$(cat "$root/VERSION")" "${signing[@]}" build
