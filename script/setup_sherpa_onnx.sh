#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNTIME_NAME="sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared"
RUNTIME_DIR="$ROOT_DIR/ThirdParty/$RUNTIME_NAME"
RUNTIME_ARCHIVE="$ROOT_DIR/ThirdParty/$RUNTIME_NAME.tar.bz2"
RUNTIME_URL="https://sourceforge.net/projects/sherpa-onnx.mirror/files/v1.13.0/$RUNTIME_NAME.tar.bz2/download"

mkdir -p "$ROOT_DIR/ThirdParty"

if [[ ! -f "$RUNTIME_DIR/lib/libsherpa-onnx-c-api.dylib" || ! -f "$RUNTIME_DIR/lib/libonnxruntime.1.24.4.dylib" ]]; then
  echo "Downloading sherpa-onnx macOS runtime..."
  curl -L --fail --retry 5 --retry-delay 2 --continue-at - -o "$RUNTIME_ARCHIVE" "$RUNTIME_URL"
  tar -xjf "$RUNTIME_ARCHIVE" -C "$ROOT_DIR/ThirdParty"
  rm -f "$RUNTIME_ARCHIVE"
fi

echo "sherpa-onnx runtime ready: $RUNTIME_DIR"
