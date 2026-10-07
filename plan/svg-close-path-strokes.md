# Task: SVG close-path stroke rendering

**Outcome:** SVG `Z`/`z` paths retain their final edge when rendered as strokes,
including closed icon contours such as gears and settings symbols.

## Scope
- [x] Trace SVG close-path parsing through the shared painter.
- [x] Preserve the close edge and SVG continuation point in flattened contours.
- [x] Add a regression test asserting the closing edge reaches the subpath start.
- [x] Run the focused SVG regression and complete portable suite.
- [ ] Verify a representative gear/settings icon on Android and inspect it at app scale.
- [x] Update SVG element coverage documentation.

## Parity
| Change | macOS/iOS | Android | Windows/Linux |
|---|---|---|---|
| Shared parser preserves final close edge | Same core output | Same core output | Same core output |

## Tests (real)
- [x] `tools/tina4pascal test` (with the configured FPC environment) — all discovered suites passed, including `test_svg` and its close-edge regression.
- [x] `tools/tina4pascal build android` — arm64-v8a compiled successfully; the subsequent armeabi-v7a build is unavailable because `ppcarm` is not installed (exit 127).
- [ ] Android emulator inspection — pending.

## Bugs
- [x] `Z`/`z` reset the current point but discarded the closing edge before the stroke painter received the contour.

## Commits
- `085680d` — `fix(svg): preserve closed stroked path edges` (PR #27)

## Status: In progress — PR #27 open; Android emulator visual verification pending.
