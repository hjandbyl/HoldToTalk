# Changelog

All notable changes to HoldToTalk will be documented in this file.

The format is based on Keep a Changelog, and this project uses semantic versioning.

## [Unreleased]

### Changed

- Reworked the recording overlay waveform into a live FFT-driven red bar visualizer with mirrored low-to-high frequency bands.

## [0.1.3] - 2026-05-22

### Added

- Added Qwen3-ASR Flash Realtime as a cloud recognition engine through the raw DashScope WebSocket protocol.
- Added separate Keychain storage and settings UI for Qwen-ASR API keys.
- Added Qwen-ASR language selection for automatic detection, Mandarin, Cantonese, and English.

### Changed

- Reorganized the project to use root-level `HoldToTalk` and `CSherpaOnnx` target folders instead of a `Sources` wrapper directory.
- Migrated app images and icons to `HoldToTalk/Assets.xcassets`.
- Removed duplicated loose resource files from the app source tree.
- Updated the local build script to compile the asset catalog with `actool`.
- Converted the Xcode project to a native app target using file system synchronized groups.
- Added repository guidance for AI coding agents and included it in the Xcode navigator.

## [0.1.2] - 2026-05-20

### Added

- Initial changelog.
