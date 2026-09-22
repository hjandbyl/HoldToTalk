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

The script stops any running `HoldToTalk` process, downloads the sherpa-onnx runtime into `ThirdParty/` if needed, builds the native Xcode target into a repository-local Derived Data directory, packages `dist/HoldToTalk.app` or `dist-adhoc/HoldToTalk.app`, embeds assets and required dylibs through the Xcode target, and signs the app. Building through the native target preserves the active SDK metadata used by macOS to select the current system appearance.

If local signing fails, use:

```bash
./script/build_and_run.sh --adhoc
```

or set `HOLDTOTALK_SIGN_IDENTITY` to a stable local signing identity. Accessibility permission is tied to code signing identity, so ad-hoc rebuilds may require re-granting Accessibility permission.

For a narrow Swift-only compilation check, use raw SwiftPM when the local sherpa runtime is already present. This avoids stopping and repackaging a currently running app. Mirror the repository cache flags:

```bash
swift build --disable-sandbox --cache-path .build/cache/swiftpm --manifest-cache local
```

If the runtime is missing, or the change touches the app target, resources, packaging, signing, or Xcode project settings, use `./script/build_and_run.sh build` instead.

When changing Xcode project structure, assets, signing, linker settings, or dylib embedding, also validate the Xcode target:

```bash
xcodebuild -quiet -project HoldToTalk.xcodeproj -scheme HoldToTalk -configuration Debug build
```

## Tool Selection

- Repository scripts and the documented CLI commands are the canonical verification path.
- When Xcode MCP tools are available, use them for Xcode-specific inspection and diagnosis, including schemes, targets, build settings, project structure, previews, and IDE-reported errors.
- Xcode MCP results do not replace the required script or CLI verification for the changed area.
- If Xcode MCP is unavailable in the current session, fall back to `xcodebuild` or the repository scripts and report that fallback.

## Testing

No XCTest target is currently defined in `Package.swift`. When changing behavior, use focused compilation checks and, for app workflows, `./script/build_and_run.sh --verify` when practical.

`./script/build_and_run.sh --verify` is a launch smoke test only: it builds the app, opens it, and checks that the process remains running. It does not validate recording, transcription, the global shortcut, Accessibility permission, or text insertion. Do not report those workflows as verified unless they were exercised separately.

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

- Before committing changes to behavior, UI, packaging, scripts, project structure, dependencies, or engineering workflow, update `CHANGELOG.md` with a clear entry in the same commit.
- Pure documentation, typo, or comment-only commits that do not alter the workflow or user-visible behavior do not require a changelog entry unless the user asks for one.

## Code Review Rules

- Flag new user-visible strings that bypass `L10n.tr(...)`.
- Flag actor-isolation violations around `@MainActor` controller state and callbacks from audio, shortcut, and recognition services.
- Treat changes to permissions, global shortcuts, audio capture, Keychain, text insertion, signing, or runtime embedding as high risk; check cleanup, error paths, and the matching verification command.
- Flag loose asset or dylib references, `Recovered References`, or project-file changes that conflict with the synchronized-group and embedding rules above.

## Verification Checklist

Use the narrowest verification that matches the change:

- Swift-only source changes, quick compilation: `swift build --disable-sandbox --cache-path .build/cache/swiftpm --manifest-cache local`
- App integration, packaging, or runtime changes: `./script/build_and_run.sh build`
- Launch behavior changes: `./script/build_and_run.sh --verify` (launch smoke test only)
- Xcode project, asset, signing, or dylib changes: `xcodebuild -quiet -project HoldToTalk.xcodeproj -scheme HoldToTalk -configuration Debug build`
- pbxproj edits: `plutil -lint HoldToTalk.xcodeproj/project.pbxproj`

Always report which checks ran, which were skipped, and why. Compilation success or the launch smoke test alone is not evidence that recording, transcription, shortcuts, permissions, or text insertion work end to end.

## Do Not

- Do not recreate `Sources/`.
- Do not recreate `HoldToTalk/Resources`.
- Do not manually add loose asset or dylib references to work around build settings.
- Do not replace the native Xcode app target with a legacy target.
- Do not move permission, event tap, Keychain, text insertion, or app lifecycle logic into SwiftUI views.
- Do not change signing identities, bundle identifiers, or runtime library versions unless the user asks for that explicitly.
