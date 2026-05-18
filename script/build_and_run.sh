#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HoldToTalk"
BUNDLE_ID="com.local.HoldToTalk"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
MODEL_DIR="$ROOT_DIR/models/$MODEL_NAME"
RUNTIME_DIR="$ROOT_DIR/ThirdParty/sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ ! -f "$MODEL_DIR/model.int8.onnx" || ! -f "$MODEL_DIR/tokens.txt" || ! -f "$RUNTIME_DIR/lib/libsherpa-onnx-c-api.dylib" || ! -f "$RUNTIME_DIR/lib/libonnxruntime.1.24.4.dylib" ]]; then
  "$ROOT_DIR/scripts/setup_sherpa_onnx.sh"
fi

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES/models" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
rm -rf "$APP_RESOURCES/models/$MODEL_NAME"
cp -R "$MODEL_DIR" "$APP_RESOURCES/models/$MODEL_NAME"
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
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHumanReadableCopyright</key>
  <string>Local development build</string>
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

  local identity="${HOLDTOTALK_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]] && command -v security >/dev/null 2>&1; then
    identity="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Apple Development/ { print $2; exit }'
    )"
  fi

  if [[ -n "$identity" ]]; then
    echo "Signing $APP_NAME with: $identity"
    codesign --force --deep --sign "$identity" "$APP_BUNDLE" >/dev/null
  else
    echo "warning: no Apple Development signing identity found; falling back to ad-hoc signing." >&2
    echo "warning: Accessibility/Input Monitoring permissions may need to be re-granted after each rebuild." >&2
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
  fi
}

if [[ "${HOLDTOTALK_SKIP_CODESIGN:-0}" != "1" ]]; then
  sign_app
fi

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
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
