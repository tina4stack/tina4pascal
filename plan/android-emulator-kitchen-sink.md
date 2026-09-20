# Task: Android emulator kitchen-sink verification

**Outcome:** Install the current Android APK on the arm64 emulator and exercise
the bundled kitchen-sink page, including a real scroll, with a screenshot and
application log check.

**Extension:** Make the Tina4Pascal CLI discover and bring up Android emulators
and iOS simulators so this verification path is self-service.

## Scope
- [x] Inspect the emulator and Android toolchain
- [x] Boot an arm64 Android Virtual Device through the CLI
- [x] Create a fresh `tina4-scroll-test` arm64 AVD (preserved the failed AVD)
- [x] Boot the fresh AVD through the CLI (default renderer; no headless GPU override)
- [x] Build, install, and launch the current APK
- [x] Exercise the kitchen-sink page and scrolling
- [x] Capture visual and log evidence; stop only processes started for this pass
- [x] Add CLI emulator/simulator discovery, boot, and readiness diagnostics
- [x] Verify the new command against real local Android and iOS toolchains

## Parity
| Target | Status |
|---|---|
| Android arm64 emulator | ✅ Fresh API 34 arm64 AVD boots and is ready through the CLI |
| iOS Simulator | ✅ CLI reports and reuses a booted iPhone Simulator |

## Tests (real)
- [x] APK install and launch on `emulator-5554`
- [x] Kitchen-sink screenshot after scroll — `/tmp/tina4pascal-emulator/kitchen-sink-scrolled-clean.png`
- [x] Runtime log check — app process remained alive; no fatal exception
- [x] Pre-change CLI gate: `emulator android status` is unknown (exit 1)
- [x] CLI syntax + Android/iOS lifecycle checks
- [x] Tina4Pascal portable suite — 20/20 passed on macOS

## Bugs
- [x] Emulator SDK component was missing and installed.
- [x] The CLI had no emulator/simulator lifecycle command.
- [x] Headless GPU overrides caused the earlier pre-ADB failures; the CLI uses the emulator's default renderer.

## Commits
- ec92dca  feat(tooling): launch mobile emulators

## Status: Complete
