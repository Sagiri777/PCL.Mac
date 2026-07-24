#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/PCL.Mac.xcodeproj}"
SCHEME="${SCHEME:-PCL.Mac}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ARCHIVE_BASENAME="${ARCHIVE_BASENAME:-PCL.Mac}"
APP_NAME="${APP_NAME:-PCL.Mac.app}"

mkdir -p "$DIST_DIR"
mkdir -p "$ROOT_DIR/build"

if [[ -n "${HTTP_PROXY:-}" && -z "${http_proxy:-}" ]]; then export http_proxy="$HTTP_PROXY"; fi
if [[ -n "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]]; then export https_proxy="$HTTPS_PROXY"; fi
if [[ -z "${NO_PROXY:-}" && -z "${no_proxy:-}" ]]; then
  export no_proxy="127.0.0.1,localhost,::1"
  export NO_PROXY="$no_proxy"
fi

if [[ ! -f "$ROOT_DIR/Secrets.xcconfig" ]]; then
  : > "$ROOT_DIR/Secrets.xcconfig"
fi

BUILD_SETTINGS=()
if [[ -n "${CLIENT_ID:-}" ]]; then
  BUILD_SETTINGS+=("CLIENT_ID=$CLIENT_ID")
fi
if [[ -n "${ARTIFACT_PAT:-}" ]]; then
  BUILD_SETTINGS+=("ARTIFACT_PAT=$ARTIFACT_PAT")
fi

echo "==> Project: $PROJECT_PATH"
echo "==> Scheme: $SCHEME ($CONFIGURATION)"
if [[ -n "${http_proxy:-}" || -n "${https_proxy:-}" ]]; then
  echo "==> Proxy: ${https_proxy:-${http_proxy:-}}"
fi

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -resolvePackageDependencies \
  ${BUILD_SETTINGS[@]+"${BUILD_SETTINGS[@]}"}

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  clean build \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  ${BUILD_SETTINGS[@]+"${BUILD_SETTINGS[@]}"}

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found: $APP_PATH" >&2
  exit 1
fi

codesign --force --deep --sign - "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1")"
STAMP="$(date +%Y%m%d-%H%M%S)"
PACKAGE_DIR="$DIST_DIR/$ARCHIVE_BASENAME-$VERSION-$BUILD-$STAMP"
ZIP_PATH="$PACKAGE_DIR.zip"

rm -rf "$PACKAGE_DIR" "$ZIP_PATH"
mkdir -p "$PACKAGE_DIR"
ditto "$APP_PATH" "$PACKAGE_DIR/$APP_NAME"

(
  cd "$DIST_DIR"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$(basename "$PACKAGE_DIR")" "$(basename "$ZIP_PATH")"
)

echo "==> Release package: $ZIP_PATH"
