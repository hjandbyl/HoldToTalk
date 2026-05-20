#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
SIGNING_MODE="${HOLDTOTALK_SIGNING_MODE:-account}"

case "$MODE" in
  --adhoc|adhoc)
    MODE="build"
    SIGNING_MODE="adhoc"
    ;;
  run-adhoc)
    MODE="run"
    SIGNING_MODE="adhoc"
    ;;
esac
APP_NAME="HoldToTalk"
BUNDLE_ID="com.local.HoldToTalk"
MIN_SYSTEM_VERSION="14.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
DEFAULT_APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$DEFAULT_APP_VERSION" ]]; then
  echo "error: VERSION is empty." >&2
  exit 1
fi
DEFAULT_BUILD_NUMBER="$(
  git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf '1'
)"
APP_VERSION="${HOLDTOTALK_VERSION:-$DEFAULT_APP_VERSION}"
APP_BUILD_NUMBER="${HOLDTOTALK_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"

if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  DIST_DIR="$ROOT_DIR/dist-adhoc"
  BUILD_CONFIGURATION="release"
else
  DIST_DIR="$ROOT_DIR/dist"
  BUILD_CONFIGURATION="debug"
fi
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_DSYM="$DIST_DIR/$APP_NAME.app.dSYM"
ACTOOL_PARTIAL_INFO_PLIST="$DIST_DIR/assetcatalog_generated_info.plist"
RUNTIME_DIR="$ROOT_DIR/ThirdParty/sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export XDG_CACHE_HOME="$ROOT_DIR/.build/cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"

if [[ ! -f "$RUNTIME_DIR/lib/libsherpa-onnx-c-api.dylib" || ! -f "$RUNTIME_DIR/lib/libonnxruntime.1.24.4.dylib" ]]; then
  "$ROOT_DIR/script/setup_sherpa_onnx.sh"
fi

SWIFT_BUILD_ARGS=(
  --disable-sandbox
  --cache-path "$XDG_CACHE_HOME/swiftpm"
  --manifest-cache local
)

if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  SWIFT_BUILD_ARGS+=("-c" "release")
fi

swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_BIN_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"

rm -rf "$APP_BUNDLE"
rm -rf "$APP_DSYM"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
if [[ -d "$BUILD_BINARY.dSYM" ]]; then
  cp -R "$BUILD_BINARY.dSYM" "$APP_DSYM"
fi
xcrun actool "$ROOT_DIR/HoldToTalk/Assets.xcassets" \
  --compile "$APP_RESOURCES" \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --target-device mac \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --bundle-identifier "$BUNDLE_ID" \
  --development-region en \
  --output-partial-info-plist "$ACTOOL_PARTIAL_INFO_PLIST" \
  >/dev/null
rm -f "$ACTOOL_PARTIAL_INFO_PLIST"
cp "$RUNTIME_DIR/lib/libsherpa-onnx-c-api.dylib" "$APP_FRAMEWORKS/"
cp "$RUNTIME_DIR/lib/libonnxruntime.1.24.4.dylib" "$APP_FRAMEWORKS/"
cp "$RUNTIME_DIR/lib/libonnxruntime.dylib" "$APP_FRAMEWORKS/" 2>/dev/null || true
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Local development build</string>
  <key>NSAccentColorName</key>
  <string>AccentColor</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>HoldToTalk records your voice while Fn is held to transcribe it into text.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_app() {
  if ! command -v codesign >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    echo "Using ad-hoc signing for $APP_NAME." >&2
    echo "warning: Accessibility permissions may need to be re-granted after each rebuild because ad-hoc signatures are not stable for TCC." >&2
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
    return 0
  fi

  local identity="${HOLDTOTALK_SIGN_IDENTITY:-}"
  if [[ -z "$identity" && "${CODE_SIGN_IDENTITY:-}" != "-" ]]; then
    identity="${CODE_SIGN_IDENTITY:-}"
  fi
  if [[ -z "$identity" ]] && command -v security >/dev/null 2>&1; then
    identity="$(
      security find-identity -p codesigning -v 2>/dev/null \
        | sed -nE 's/.*"((HoldToTalk Local Code Signing|Apple Development|Mac Developer|Developer ID Application):[^"]*)".*/\1/p' \
        | head -n 1
    )"
  fi

  if [[ -n "$identity" ]]; then
    echo "Signing $APP_NAME with: $identity"
    codesign --force --deep --sign "$identity" "$APP_BUNDLE" >/dev/null
  else
    echo "error: no code signing identity found for account signing." >&2
    echo "Set HOLDTOTALK_SIGN_IDENTITY, install an Apple Development certificate, or run './script/build_and_run.sh --adhoc' for an ad-hoc package." >&2
    return 1
  fi
}

if [[ "${HOLDTOTALK_SKIP_CODESIGN:-0}" != "1" ]]; then
  sign_app
fi

echo "Built $APP_BUNDLE using $BUILD_CONFIGURATION configuration."

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --adhoc|adhoc|run-adhoc)
    ;;
  build)
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|build|--adhoc|run-adhoc|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
