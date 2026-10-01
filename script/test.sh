#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_LIB="$ROOT_DIR/ThirdParty/sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared/lib"
if [[ ! -f "$RUNTIME_LIB/libsherpa-onnx-c-api.dylib" ]]; then
  echo "Missing sherpa runtime. Run ./script/setup_sherpa_onnx.sh first." >&2
  exit 1
fi
cd "$ROOT_DIR"
export DYLD_LIBRARY_PATH="$RUNTIME_LIB${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec swift test --disable-sandbox --cache-path .build/cache/swiftpm --manifest-cache local -Xlinker -rpath -Xlinker "$RUNTIME_LIB" "$@"
