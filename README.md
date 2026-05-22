# HoldToTalk

Hold a shortcut, speak, release it, and the recognized text is pasted into the currently focused macOS app.

## Download

Download the latest macOS arm64 build from GitHub Releases:

- https://github.com/hjandbyl/HoldToTalk/releases

The release build is ad-hoc signed. On first launch, macOS may require you to approve opening the app and grant the permissions listed below.

## Build from Source

Build and run the macOS app:

```bash
./script/build_and_run.sh
```

The build script automatically downloads the sherpa-onnx macOS runtime into `ThirdParty/` if it is missing.

Create an ad-hoc signed release app bundle:

```bash
./script/build_and_run.sh --adhoc
```

Ad-hoc packages are built with SwiftPM release mode and written to `dist-adhoc/HoldToTalk.app`. Development builds use `dist/HoldToTalk.app`.

The default bundle version is read from the root `VERSION` file. `HOLDTOTALK_VERSION` and `HOLDTOTALK_BUILD_NUMBER` can override packaging metadata when needed.

## Permissions

Grant these macOS permissions to `HoldToTalk.app` when prompted:

- Microphone
- Accessibility

Accessibility is needed for global shortcut detection and text insertion into the focused app.

## Recognition

HoldToTalk supports three recognition engines:

- `Doubao Streaming Speech Recognition 2.0`: cloud streaming recognition with partial text while recording and a final result after release.
- `Qwen3-ASR Flash Realtime`: DashScope WebSocket cloud streaming recognition with partial text while recording and a final result after release.
- `sherpa-onnx Local`: offline recognition from the full recording after release.

Set the cloud recognition API key in the app window. Keys are saved to the macOS Keychain and are not stored in source code.

Local ASR models are not bundled in the app package. Choose and download a SenseVoice or FireRedASR model from the Recognition panel. Downloaded local models are stored under the user's Application Support directory at `HoldToTalk/models`; development builds also detect matching model folders under the repository's root `models` directory.

SenseVoice local models use `use_itn=1` so Chinese output can include inverse text normalization and punctuation when supported by the selected model.

## Local Code Signing

Accessibility permission is tied to the app's code signing identity. Ad-hoc signing changes the code identity on rebuild, so macOS may require Accessibility permission again after each compile.

For local development, use a stable code signing certificate:

```bash
HOLDTOTALK_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./script/build_and_run.sh
```

If `HOLDTOTALK_SIGN_IDENTITY` is not set, the build script will try to use the first available `HoldToTalk Local Code Signing`, `Apple Development`, `Mac Developer`, or `Developer ID Application` identity. If none exists, run `./script/build_and_run.sh --adhoc` to create an ad-hoc package.

## Requirements

- macOS 14 or later
- Apple silicon Mac for the current arm64 runtime and release build
- Xcode command line tools when building from source

## License

HoldToTalk is licensed under the GNU General Public License v3.0. See `LICENSE` for details.
