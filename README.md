# HoldToTalk

Hold Fn, speak, release Fn, and the recognized text is pasted into the currently focused macOS app.

## Setup

Download the sherpa-onnx macOS runtime and the SenseVoice 2025-09-09 ONNX model once:

```bash
./scripts/setup_sherpa_onnx.sh
```

Then build and run the macOS app:

```bash
./script/build_and_run.sh
```

The app defaults to `Volcengine Cloud` for streaming recognition and keeps `sherpa-onnx Local` as an offline fallback.

## Permissions

Grant these macOS permissions to `HoldToTalk.app` when prompted:

- Microphone
- Accessibility
- Input Monitoring

Accessibility is needed for text insertion. Input Monitoring is needed for global Fn key detection.

## Runtime Configuration

Optional environment variables:

- `VOLCENGINE_API_KEY`: cloud ASR API key for local debugging
- `SHERPA_ONNX_SENSEVOICE_DIR`: local SenseVoice ONNX model directory
- `SHERPA_ONNX_SENSEVOICE_MODEL`: explicit path to `model.int8.onnx` or `model.onnx`
- `SHERPA_ONNX_SENSEVOICE_TOKENS`: explicit path to `tokens.txt`

By default the cloud key is read from this macOS Keychain entry:

```bash
security add-generic-password -U -s HoldToTalk.volcengine -a api-key -w "$VOLCENGINE_API_KEY"
```

`Volcengine Cloud` streams partial text while recording and returns a final result after release. `sherpa-onnx Local` still transcribes from the full recording after release.
