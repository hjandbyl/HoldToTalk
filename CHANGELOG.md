# Changelog

All notable changes to HoldToTalk will be documented in this file.

The format is based on Keep a Changelog, and this project uses semantic versioning.

## [Unreleased]

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
