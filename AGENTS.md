# Repository Guidelines

## Project Overview

HoldToTalk is a macOS 14+ SwiftUI menu bar/window app. It records while a hold shortcut is pressed, transcribes speech through either Volcengine cloud streaming or local sherpa-onnx, then can paste the recognized text into the focused app.

The repository is package-first SwiftPM with an accompanying native Xcode app project:

- `Package.swift` defines the `HoldToTalk` executable target and the `CSherpaOnnx` C target.
- `HoldToTalk/` contains the app target source, SwiftUI views, support code, and `Assets.xcassets`.
- `CSherpaOnnx/` contains the C bridge target used by Swift to import sherpa-onnx C APIs.
- `ThirdParty/` contains the local sherpa-onnx runtime payload used for linking and packaging.
- `script/` contains build, packaging, setup, and icon generation scripts.

Do not recreate a `Sources/` wrapper directory. The canonical source layout is root-level `HoldToTalk/` and `CSherpaOnnx/`.

## Build And Run

Primary local command:

```bash
./script/build_and_run.sh
```

Useful variants:

```bash
./script/build_and_run.sh build
./script/build_and_run.sh --adhoc
./script/build_and_run.sh run-adhoc
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

The script downloads the sherpa-onnx runtime into `ThirdParty/` if needed, builds with SwiftPM, packages `dist/HoldToTalk.app` or `dist-adhoc/HoldToTalk.app`, compiles `HoldToTalk/Assets.xcassets` with `actool`, copies required dylibs, writes `Info.plist`, and signs the app.

If local signing fails, use:

```bash
./script/build_and_run.sh --adhoc
```

or set `HOLDTOTALK_SIGN_IDENTITY` to a stable local signing identity. Accessibility permission is tied to code signing identity, so ad-hoc rebuilds may require re-granting Accessibility permission.

For pure compilation checks, prefer the script over raw `swift build` because the script sets cache paths and ensures the local sherpa runtime is present. If raw SwiftPM is needed, mirror the script's flags:

```bash
swift build --disable-sandbox --cache-path .build/cache/swiftpm --manifest-cache local
```

When changing Xcode project structure, assets, signing, linker settings, or dylib embedding, also validate the Xcode target:

```bash
xcodebuild -quiet -project HoldToTalk.xcodeproj -scheme HoldToTalk -configuration Debug build
```

## Testing

No XCTest target is currently defined in `Package.swift`. When changing behavior, use focused compilation checks and, for app workflows, `./script/build_and_run.sh --verify` when practical.

## Architecture Notes

- `HoldToTalk/App/HoldToTalkApp.swift` owns the SwiftUI app entry, app delegate, main window, and menu bar extra.
- `HoldToTalk/Stores/HoldToTalkController.swift` is the main `@MainActor` observable controller. Extensions split application state, recording, and recognition behavior.
- `HoldToTalk/Services/` contains integration boundaries for audio capture, global shortcut monitoring, text injection, Keychain, cloud streaming, local sherpa recognition, and the transcription overlay.
- `HoldToTalk/Views/` contains SwiftUI surfaces. `ContentView` is split with section/helper extensions.
- `HoldToTalk/Support/L10n.swift` provides localized strings through `L10n.tr(...)`; use it for user-visible text.
- Local model metadata and install state are managed by `LocalSpeechModel` and `LocalSpeechModelStore`.

Keep UI changes consistent with the existing SwiftUI split-view structure and AppKit interop boundaries. Avoid moving app lifecycle, permissions, keyboard monitoring, or text insertion behavior into views.

## Xcode Project Rules

- The Xcode project uses File System Synchronized Groups for `HoldToTalk/`, `CSherpaOnnx/`, `ThirdParty/`, and `script/`.
- The app target's `fileSystemSynchronizedGroups` should contain only the app source root, `HoldToTalk/`.
- Root-level documentation files are not automatically synchronized. If you add files such as `AGENTS.md`, `CHANGELOG.md`, or `README.md`, add explicit `PBXFileReference` entries so they appear in Xcode.
- Do not add loose PNG, ICNS, or dylib file references to the navigator just to make builds work.
- Do not leave or introduce `Recovered References`.
- After editing `HoldToTalk.xcodeproj/project.pbxproj`, run `plutil -lint HoldToTalk.xcodeproj/project.pbxproj` and `xcodebuild -list -project HoldToTalk.xcodeproj`.

## Resource Rules

- `HoldToTalk/Assets.xcassets` is the single source for app icons, accent color, and menu bar template images.
- Do not recreate `HoldToTalk/Resources`.
- `script/generate_icons.swift` writes generated icon assets directly into `HoldToTalk/Assets.xcassets`.
- `script/build_and_run.sh` must compile the asset catalog with `actool`; do not package loose image files as a fallback.
- App bundles should contain compiled resource outputs such as `Assets.car` and `AppIcon.icns`, not scattered source PNGs.

## Dependencies And Runtime

The `CSherpaOnnx` target links against the arm64 sherpa-onnx runtime expected at:

```text
ThirdParty/sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared
```

Do not commit downloaded runtime binaries unless the user asks for release artifact changes. The runtime is packaged into the app bundle by `script/build_and_run.sh`.

Keep dylib linking in build settings and dylib embedding in the `Embed ThirdParty Dylibs` build phase script. Avoid adding the dylibs as loose `PBXFileReference` entries, because that can create navigator clutter and recovered references.

## Coding Conventions

- Use Swift concurrency deliberately; the main controller is `@MainActor`.
- Keep user-facing strings localized with `L10n.tr(...)`.
- Preserve the current file organization by feature boundary: app entry, stores, services, support, models, and views.
- Prefer narrow changes over broad refactors, especially around permissions, global event taps, Keychain, and text insertion.
- Do not revert unrelated dirty worktree changes.

## Commit Rules

- Before every commit, update `CHANGELOG.md` with a clear entry for the user-visible or engineering changes being committed.
- Do not create a commit that changes behavior, UI, packaging, scripts, or project structure without including the corresponding changelog update in the same commit.

## Verification Checklist

Use the narrowest verification that matches the change:

- Swift-only source changes: `swift build --disable-sandbox --cache-path .build/cache/swiftpm --manifest-cache local`
- Packaging or runtime changes: `./script/build_and_run.sh build`
- Launch behavior changes: `./script/build_and_run.sh --verify`
- Xcode project, asset, signing, or dylib changes: `xcodebuild -quiet -project HoldToTalk.xcodeproj -scheme HoldToTalk -configuration Debug build`
- pbxproj edits: `plutil -lint HoldToTalk.xcodeproj/project.pbxproj`

## Do Not

- Do not recreate `Sources/`.
- Do not recreate `HoldToTalk/Resources`.
- Do not manually add loose asset or dylib references to work around build settings.
- Do not replace the native Xcode app target with a legacy target.
- Do not move permission, event tap, Keychain, text insertion, or app lifecycle logic into SwiftUI views.
- Do not change signing identities, bundle identifiers, or runtime library versions unless the user asks for that explicitly.
