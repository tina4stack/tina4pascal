# Sheep3D — walking Merino ram (ThreePascal)

A faithful port of the virtual-office ram (`ram-builder.js`) rendered by
**ThreePascal** — the pure-software three.js port in `../../3d`. No OpenGL, no
GPU: each frame is rasterised on the CPU to an RGBA buffer and blitted into a
Cocoa window via `NSImage`.

- `RamModel.pas` — `BuildRam` (icosahedron fleece, boxed skeleton, spiral horns,
  jointed legs) + `RamWalkClip` (ported Euler keyframes).
- `sheepapp.pas` — the macOS app (window + timer + AnimationMixer).
- `sheep_snapshot.pas` — headless walk-cycle montage → BMP (verification).

## Build & run
```sh
./build.sh
open "${TMPDIR:-/tmp}/sheep3d/Sheep3D.app"
```
Needs the self-contained FPC at `~/fpc`. The `-ld_classic` flag works around the
macOS 26 linker asserting on FPC 3.2.2's Objective-C metadata.
