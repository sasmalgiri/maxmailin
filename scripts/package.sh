#!/bin/bash
# Build maxmailin as a Mac `.app` bundle from the SPM executable.
#
# Output: build/maxmailin.app
#
# Usage:
#   scripts/package.sh [--version 0.1.0] [--build 1] [--no-sign]
#
# The bundle is ad-hoc signed by default (codesign with '-' identity) so
# it can be double-clicked locally; Gatekeeper will warn the first time.
# For Mac App Store / Developer ID distribution, re-sign the produced
# bundle with your real identity and a sibling entitlements file.

set -euo pipefail

VERSION="0.1.0"
BUILD="1"
DO_SIGN="yes"

while (( "$#" )); do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build)   BUILD="$2";   shift 2 ;;
        --no-sign) DO_SIGN="no"; shift   ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *)
            echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Prefer Xcode's swift toolchain so XCTest / SwiftUI link cleanly.
if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "→ swift build -c release"
xcrun swift build -c release

EXEC_NAME="maxmail-app"
EXEC_PATH=".build/release/${EXEC_NAME}"
if [[ ! -x "${EXEC_PATH}" ]]; then
    echo "Build did not produce ${EXEC_PATH}" >&2
    exit 1
fi

APP_DIR="build/maxmailin.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

echo "→ laying out ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

# Copy the executable.
cp "${EXEC_PATH}" "${MACOS_DIR}/${EXEC_NAME}"
chmod +x "${MACOS_DIR}/${EXEC_NAME}"

# Render Info.plist with the requested version + build number.
sed -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUILD__/${BUILD}/g" \
    Resources/Info.plist > "${CONTENTS}/Info.plist"

# PkgInfo is the legacy 8-byte tag macOS still inspects when probing bundles.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Drop in an icon if one has been provided. .icns is preferred — Apple's
# documented icon format — but the script also accepts a single PNG and
# leaves a note for the user when neither is present.
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
elif [[ -f "Resources/AppIcon.png" ]]; then
    cp "Resources/AppIcon.png" "${RES_DIR}/AppIcon.png"
    # Older macOS will still pick up a generic icon, but the file is here
    # so a follow-up `iconutil` pass can build a proper .icns.
fi

# Ad-hoc code signing. Without this the binary often gets killed by
# Gatekeeper's hardened runtime defaults; with it the user only sees the
# usual "downloaded from the internet" prompt the first time.
if [[ "${DO_SIGN}" == "yes" ]]; then
    echo "→ ad-hoc codesign"
    codesign --force --deep \
        --entitlements Resources/maxmailin.entitlements \
        --sign - "${APP_DIR}"
    codesign --verify --deep --strict "${APP_DIR}" \
        && echo "✓ signature verifies"
else
    echo "→ skipping codesign (--no-sign)"
fi

echo ""
echo "✓ Built ${APP_DIR}"
echo "  Version: ${VERSION} (build ${BUILD})"
echo "  Run with: open ${APP_DIR}"
echo "  Install:  cp -R ${APP_DIR} /Applications/"
