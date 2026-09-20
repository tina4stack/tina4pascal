# Task: README mobile emulator commands

**Outcome:** Document the Tina4Pascal commands that start local Android
emulators and iOS simulators without implying that the iOS device build runs in
the simulator.

## Scope
- [x] Add a short mobile-run section to the README
- [x] Add `emulator` to the CLI surface summary
- [x] Verify the commands and README links match the CLI

## Parity
| Target | README command |
|---|---|
| Android emulator | `emulator android start` |
| iOS Simulator | `emulator ios start` |

## Tests (real)
- [x] CLI help and both lifecycle status commands

## Bugs
- [x] README did not expose the mobile emulator/simulator lifecycle commands.

## Commits
- 08b3c51  docs: document mobile emulator commands

## Status: Complete
