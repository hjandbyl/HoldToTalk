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
It builds the native Xcode target so the packaged app retains the active SDK metadata required for the current macOS appearance.

Create an ad-hoc signed release app bundle:

```bash
./script/build_and_run.sh --adhoc
```

Ad-hoc packages are built with the native Xcode target in Release mode and written to `dist-adhoc/HoldToTalk.app`. Development builds use `dist/HoldToTalk.app`.

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

Local ASR models are not bundled in the app package. Choose and download a SenseVoice, FireRedASR, or Whisper model from the Recognition panel. Downloaded local models are stored under the user's Application Support directory at `HoldToTalk/models`; development builds also detect matching model folders under the repository's root `models` directory.

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
- Xcode 27 command line tools when building from source

## Architecture and Testing

`AppEnvironment` assembles the services and owns application lifecycle. SwiftUI pages subscribe to their relevant settings, credentials, device/permission, model, recording, and diagnostics stores. `DictationCoordinator` owns per-recording configuration snapshots and processes completed results in capture order. The old global controller is no longer used.

Each cloud recording owns a single-use streaming session. The active microphone can record the next segment while earlier segments finish. Local recognition runs serially and caches at most one model/language combination. Up to eight unfinished segments are admitted; when full, the next recording is rejected with a visible message. Recording callbacks copy PCM into a preallocated two-second SPSC pool; a serial worker writes, converts, and analyzes it. Cloud PCM buffering is limited to ten seconds. Overflow, network errors, and timeouts fail only the affected segment. Runtime cloud failures do not retry, return partial text as success, or switch engines. Selecting a cloud engine without a saved key retains the existing startup fallback to local recognition.

All text insertion uses the application captured when that recording began. Results are inserted in recording order. An unavailable target fails without inserting into another app. Keyboard event dispatch is reported as sent, since the app cannot prove an editor accepted it.

Run tests without starting the app or accessing the microphone, Keychain, or cloud accounts:

```bash
./script/test.sh
```

The script uses the existing sherpa runtime and adds its directory to the test build's rpath. Tests use fake recognition/capture/insertion services and a controllable clock, plus isolated temporary files and a private pasteboard. The native Xcode scheme remains the application build; automated tests run through SwiftPM.

Validation commands:

```bash
swift build --disable-sandbox --cache-path .build/cache/swiftpm --manifest-cache local
./script/build_and_run.sh build
xcodebuild -quiet -project HoldToTalk.xcodeproj -scheme HoldToTalk -configuration Debug build
./script/build_and_run.sh --verify
```

The last command is only a process launch smoke test. Manually verify all three engines with built-in, USB, and Bluetooth microphones; short presses, rapid successive recordings, disconnect/reconnect and revoked permissions; native text fields and web editors; and user clipboard changes during insertion. Do not equate a passing build or launch check with verified recording or insertion.

Refactor validation on 2026-10-01:

- 40 XCTest cases passed with `./script/test.sh -Xswiftc -strict-concurrency=complete`; no compiler warnings. The suite covers fake-service 100-segment cleanup and accelerated five-minute PCM ordering, receive failures while capture is active, connection/send/final timeouts, and cancelled or stale operations.
- Six concurrent audio/continuation tests passed with `./script/test.sh --sanitize thread --filter ConcurrencyPrimitiveTests` without Thread Sanitizer reports.
- SwiftPM compilation, the native packaging command, native Debug `xcodebuild`, and `--verify` passed. Xcode MCP inspected the native app target and reported no code issues for the updated text injector. Overview and Diagnostics were inspected in the running app; diagnostic audio retention was off.
- A five-second idle sampler run produced CPU/RSS output and correctly left recognition timings unmeasured. This was a sampler smoke check, not a performance comparison.
- Real speech recognition, all microphone types, shortcut/permission changes, native/web insertion, model memory release, and matched before/after P50/P95, CPU, and memory measurements remain unverified. They require the manual matrix above and matched input; no performance improvement is claimed.
- No Xcode project file, signing identity, Bundle ID, asset catalog, or runtime version was changed. Project-file lint/list checks were therefore not required for this refactor.

## Performance and Diagnostics

The Diagnostics page shows the latest recording timings and an opt-in **Retain diagnostic audio** switch (off by default). When enabled, the last successful recording is copied to the temporary directory as `HoldToTalk-last.wav`. Failed recordings are always deleted. Turn the switch off to remove the retained copy. Session logs contain IDs, engine, timings, queue sizes, and outcome categories; they contain no credentials, transcript, or audio. Timings distinguish the first captured frame, release-to-result, and result-to-insertion dispatch, including queue wait.

Sample an already running app while exercising a repeatable workflow:

```bash
./script/measure_performance.py --duration 60 --label cloud-warm --output .build/perf-before.json
./script/measure_performance.py --duration 60 --label cloud-warm --baseline .build/perf-before.json --output .build/perf-after.json
```

Use the same Mac, build configuration, engine/model, microphone, audio, and thermal conditions. Measure idle, cold and warm starts, 100 consecutive segments, five-minute recordings, and model/language switching separately. The sampler reports process CPU, peak/start/end RSS, per-engine timing P50/P95, failures, and network buffer peaks. Comparisons over 10% are flagged and return a nonzero exit code; reproduce them before accepting a release. Missing timing data is **unmeasured**, not zero. Resource samples alone cannot prove recognition performance improved. The automated five-minute PCM and 100-segment tests validate ordering and bounded resources, not real-time device behavior or speech quality.

## License

HoldToTalk is licensed under the GNU General Public License v3.0. See `LICENSE` for details.
