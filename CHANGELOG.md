# Changelog

All notable changes to HoldToTalk will be documented in this file.

The format is based on Keep a Changelog, and this project uses semantic versioning.

## [Unreleased]

### Fixed

- Fall back to automatic microphone selection when the saved input device is no longer available.

## [0.1.5] - 2026-06-11

### Added

- Added microphone selection to the status bar menu with the current input shown in the top-level menu title.
- Added manual microphone input selection with an automatic system-default option.
- Added a temporary API key reveal button for cloud recognition credentials.
- Added generated template menu bar icons that match the app icon's voice-mark style.

### Changed

- Filtered Core Audio default aggregate input devices from user-facing microphone choices.
- Tightened the settings microphone refresh button layout so it stays next to the device picker.
- Removed the menu bar permissions request action so permission management stays in the main window.
- Documented the requirement to update `CHANGELOG.md` before every commit.
- Switched the menu bar extra from SF Symbols to generated asset-catalog template images.

### Fixed

- Fixed a settings view crash caused by AppStorage-backed SwiftUI pickers when opening the Settings section.

## [0.1.4] - 2026-06-01

### Changed

- Reworked the recording overlay waveform into a live FFT-driven red bar visualizer with mirrored low-to-high frequency bands.
- Replaced custom menu bar template image assets with SF Symbol status icons for idle, recording, and transcribing states.
- Redesigned the app icon as a minimal dark voice mark with a recording-accent hold indicator.
- Centralized recording accent colors in asset catalog color sets and reused them across the overlay, main UI, and icon generation.
- Updated icon generation so the app icon reads recording accent colors from asset catalog assets.

### Removed

- Removed generated menu bar template image assets now covered by SF Symbols.

## [0.1.3] - 2026-05-22

This release broadens recognition choices and cleans up the native macOS project layout. It adds Qwen cloud ASR, expands local offline ASR with Whisper models, and keeps the package-first SwiftPM workflow aligned with the Xcode app target.

### Added

- Added Qwen3-ASR Flash Realtime as a cloud recognition engine through the raw DashScope WebSocket protocol.
- Added separate Keychain storage and settings UI for Qwen-ASR API keys.
- Added Qwen-ASR language selection for automatic detection, Mandarin, Cantonese, and English.
- Added Whisper Tiny, Base, Small, and Medium int8 models to local recognition through sherpa-onnx.
- Added multilingual Whisper language selection for local offline recognition.

### Changed

- Reorganized the project to use root-level `HoldToTalk` and `CSherpaOnnx` target folders instead of a `Sources` wrapper directory.
- Migrated app images and icons to `HoldToTalk/Assets.xcassets`.
- Removed duplicated loose resource files from the app source tree.
- Updated the local build script to compile the asset catalog with `actool`.
- Converted the Xcode project to a native app target using file system synchronized groups.
- Added repository guidance for AI coding agents and included it in the Xcode navigator.
- Updated local model metadata and sherpa-onnx recognizer setup so each local model family can provide its own token files, model files, and language hints.

## [0.1.2] - 2026-05-20

### Added

- Initial changelog.
