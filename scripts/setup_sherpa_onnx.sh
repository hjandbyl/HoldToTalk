#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
MODEL_DIR="$ROOT_DIR/models/$MODEL_NAME"
MODEL_ARCHIVE="$ROOT_DIR/models/$MODEL_NAME.tar.bz2"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL_NAME.tar.bz2"

RUNTIME_NAME="sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared"
RUNTIME_DIR="$ROOT_DIR/ThirdParty/$RUNTIME_NAME"
RUNTIME_ARCHIVE="$ROOT_DIR/ThirdParty/$RUNTIME_NAME.tar.bz2"
RUNTIME_URL="https://sourceforge.net/projects/sherpa-onnx.mirror/files/v1.13.0/$RUNTIME_NAME.tar.bz2/download"

mkdir -p "$ROOT_DIR/models" "$ROOT_DIR/ThirdParty"

if [[ ! -f "$MODEL_DIR/model.int8.onnx" || ! -f "$MODEL_DIR/tokens.txt" ]]; then
  echo "Downloading sherpa-onnx SenseVoice model..."
  curl -L --fail --retry 5 --retry-delay 2 --continue-at - -o "$MODEL_ARCHIVE" "$MODEL_URL"
  tar -xjf "$MODEL_ARCHIVE" -C "$ROOT_DIR/models"
  rm -f "$MODEL_ARCHIVE"
fi

if [[ ! -f "$RUNTIME_DIR/lib/libsherpa-onnx-c-api.dylib" || ! -f "$RUNTIME_DIR/lib/libonnxruntime.1.24.4.dylib" ]]; then
  echo "Downloading sherpa-onnx macOS runtime..."
  curl -L --fail --retry 5 --retry-delay 2 --continue-at - -o "$RUNTIME_ARCHIVE" "$RUNTIME_URL"
  tar -xjf "$RUNTIME_ARCHIVE" -C "$ROOT_DIR/ThirdParty"
  rm -f "$RUNTIME_ARCHIVE"
fi

echo "sherpa-onnx model ready: $MODEL_DIR"
echo "sherpa-onnx runtime ready: $RUNTIME_DIR"
