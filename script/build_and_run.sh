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
  BUILD_CONFIGURATION="Release"
else
  DIST_DIR="$ROOT_DIR/dist"
  BUILD_CONFIGURATION="Debug"
fi
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_DSYM="$DIST_DIR/$APP_NAME.app.dSYM"
RUNTIME_DIR="$ROOT_DIR/ThirdParty/sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared"
XCODE_DERIVED_DATA="$ROOT_DIR/.build/xcode-derived-data"
XCODE_PRODUCTS_DIR="$XCODE_DERIVED_DATA/Build/Products/$BUILD_CONFIGURATION"
XCODE_APP_BUNDLE="$XCODE_PRODUCTS_DIR/$APP_NAME.app"
XCODE_APP_DSYM="$XCODE_PRODUCTS_DIR/$APP_NAME.app.dSYM"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ ! -f "$RUNTIME_DIR/lib/libsherpa-onnx-c-api.dylib" || ! -f "$RUNTIME_DIR/lib/libonnxruntime.1.24.4.dylib" ]]; then
  "$ROOT_DIR/script/setup_sherpa_onnx.sh"
fi

xcodebuild -quiet \
  -project "$ROOT_DIR/HoldToTalk.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$BUILD_CONFIGURATION" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$XCODE_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$APP_BUILD_NUMBER" \
  build

rm -rf "$APP_BUNDLE"
rm -rf "$APP_DSYM"
mkdir -p "$DIST_DIR"
cp -R "$XCODE_APP_BUNDLE" "$APP_BUNDLE"
if [[ -d "$XCODE_APP_DSYM" ]]; then
  cp -R "$XCODE_APP_DSYM" "$APP_DSYM"
fi

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

echo "Built $APP_BUNDLE using Xcode $BUILD_CONFIGURATION configuration."

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
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
