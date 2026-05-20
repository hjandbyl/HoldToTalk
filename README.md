# HoldToTalk

Hold Fn, speak, release Fn, and the recognized text is pasted into the currently focused macOS app.

## Setup

Download the sherpa-onnx macOS runtime once:

```bash
./script/setup_sherpa_onnx.sh
```

Then build and run the macOS app:

```bash
./script/build_and_run.sh
```

Create an ad-hoc signed release app bundle:

```bash
./script/build_and_run.sh --adhoc
```

Ad-hoc packages are built with SwiftPM release mode and written to `dist-adhoc/HoldToTalk.app`. Development builds still use `dist/HoldToTalk.app`.

The app defaults to `Doubao Streaming Speech Recognition 2.0` for streaming recognition and keeps `sherpa-onnx Local` as an offline fallback. Local ASR models are not bundled in the app package; choose and download a SenseVoice or FireRedASR model from the Recognition panel.

## Local Code Signing

Accessibility permission is tied to the app's code signing identity. Ad-hoc signing changes the code identity on rebuild, so macOS may require Accessibility permission again after each compile.

For local development, use a stable code signing certificate:

```bash
HOLDTOTALK_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./script/build_and_run.sh
```

If `HOLDTOTALK_SIGN_IDENTITY` is not set, the build script will try to use the first available `HoldToTalk Local Code Signing`, `Apple Development`, `Mac Developer`, or `Developer ID Application` identity. If none exists, it falls back to ad-hoc signing and Accessibility permission may be reset on rebuild.

## Permissions

Grant these macOS permissions to `HoldToTalk.app` when prompted:

- Microphone
- Accessibility

Accessibility is needed for global Fn key detection and text insertion.

## Runtime Configuration

Set the Doubao Streaming Speech Recognition 2.0 API key in the app window. The key is saved to the macOS Keychain and is not stored in source code.

Downloaded local models are stored under the user's Application Support directory at `HoldToTalk/models`. Development builds also detect matching model folders under the repository's root `models` directory.

`Doubao Streaming Speech Recognition 2.0` streams partial text while recording and returns a final result after release. `sherpa-onnx Local` still transcribes from the full recording after release.

SenseVoice local models use `use_itn=1` so Chinese output can include inverse text normalization and punctuation when supported by the selected model.
