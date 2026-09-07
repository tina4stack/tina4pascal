# Office3D — walkable office (ThreePascal)

A first-person walk through an office floor rendered by **ThreePascal** (the pure
software three.js port in `../../3d`). No OpenGL, no GPU, no logins, no video —
each frame is rasterised on the CPU (2× anti-aliased) and blitted into a Cocoa
window via `NSImage`.

- `OfficeScene.pas` — `BuildOffice`: floor, walls, desk bullpen, glass meeting
  room, reception, plants, a Torus wall clock, seated avatars.
- `officeapp.pas` — the macOS app: first-person camera + input.
- `office_snapshot.pas` — headless still → BMP.

Controls: **WASD** move · **arrow keys** look · **Esc** quit (click the window first).

## Build & run
```sh
./build.sh
open "${TMPDIR:-/tmp}/office3d/Office3D.app"
```
Needs the self-contained FPC at `~/fpc`. `-ld_classic` works around the macOS 26
linker vs FPC 3.2.2 Objective-C metadata.
