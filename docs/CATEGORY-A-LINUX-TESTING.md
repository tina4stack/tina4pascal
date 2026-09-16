# Category A on Linux — a testing plan for the software-path fidelity items

Category A is rendering fidelity on the **software / raster path** — the Xlib
(Linux), GDI (Windows) and pure-raster (watch/Android) canvases. macOS and iOS
run on Core Graphics / Core Text and are already complete there, so a macOS
`--snapshot` can never exercise these last A items: it will always take the
Cocoa path. To prove them we have to render on the target itself. This plan
picks **Linux/Xlib** as that target, because the shell already builds from this
Mac by cross-compile, it needs nothing but an X server (a headless `Xvfb` will
do), and its canvas is plain Xlib we can read end to end.

The three A items still open:

1. **Desktop `BlendPixel` → the shared `BlendRGB`.** `Tina4ShellLinux.pas:203`
   carries its **own** `BlendRGB`, "a straight port of the Windows shell's
   BlendPixel" — separable modes only, and every call site passes `''` for the
   non-separable ones. The shared `Tina4RenderBackend.BlendRGB` covers the full
   set (dodge/burn plus `hue`/`saturation`/`color`/`luminosity`). Routing the
   shell through it gives `mix-blend-mode` and `background-blend-mode` the whole
   set on Linux and Windows. **Reachable and directly testable on Linux.**
2. **HiDPI / supersampling.** The shells run at density 1 with no supersampling.
   The engine already takes a density argument; the shell has to read the X
   display DPI and size its pixmap and layer buffers to match. **Reachable and
   testable on Linux.**
3. **`clip-path` under a transform.** On Windows this is the device-space GDI
   clip ignoring the world transform (`Tina4ShellWin.pas:771`). On Linux it is
   **not reachable yet**: the X11 canvas has no affine transform at all —
   `Translate`/`Rotate`/`Scale` are the contract's no-op defaults, unoverridden
   (`Tina4ShellLinux.pas`), so a clip has no CTM to lag behind. This is a
   Windows-primary item; on Linux it sits behind a larger prerequisite (add an
   affine matrix to the X11 canvas, which would also make CSS transforms and
   vertical writing-mode paint rotated on Linux instead of upright). Tracked
   here, deprioritised.

So the plan verifies **(1)** first — the clear win — then **(2)**, and records
**(3)** as prerequisite work rather than a quick check.

## The environment

Anything that gives FPC 3.2.2 and an X server works. Two shapes, either is fine.

- **A real Linux box** (x86-64 or arm64). Install FPC 3.2.2, clone the repo,
  build natively (no cross flags). Simplest when one is to hand.
- **Docker on this Mac**, for a reproducible headless run. A Debian image with
  `fpc`, `xvfb`, `xauth` and `imagemagick`, the repo mounted in. `Xvfb` gives
  the shell a display with no monitor, so the whole suite runs in CI.

The reference is the same headless Chrome the macOS gate already uses
(`tools/run-compliance.sh`), run against the same HTML so the two snapshots are
comparable pixel-for-pixel.

## Building the Linux shell — through the CLI, not raw `fpc`

The Linux entry program is `examples/htmlviewer/htmlviewer_x11.pas` (the plain
`htmlviewer.pas` pulls in the Cocoa shell and is macOS-only). `tools/tina4pascal`
already knows how to build it — one verb, and downstream devs get the same:

```sh
tools/tina4pascal build linux        # → build/linux/htmlviewer_x11 (a real Linux ELF)
```

Verified from this Mac: the CLI cross-compiles and **links** a stripped x86-64
ELF (`-Tlinux -Px86_64`), using an `libX11.so` stub the CLI sets up under
`$TINA4_HOME/xstub` so the cross-link resolves the X symbols. `build linux-arm64`
does the same for arm64. The ELF does **not** run here — it needs a Linux loader
and an X server — so it is copied to the Linux box or container to run.

## Headless capture — already wired

`LinSaveBmp` (`Tina4ShellLinux.pas:1019`) reads the pixmap back with `XGetImage`
and writes a BMP, the Linux equivalent of the Cocoa `--snapshot` PNG, and the
CLI already drives it under `Xvfb` when there is no `DISPLAY`:

```sh
# on the Linux box (or container); the CLI wraps in xvfb-run when headless
tools/tina4pascal screenshot linux page.html out.bmp
convert out.bmp out.png     # ImageMagick, so the diff tooling reads it
```

So the capture path exists end to end — build, headless run, BMP out — and each
item below is a matter of feeding it the right page and diffing the result. Any
new device capability the tests need (a density flag, a second snapshot size)
goes into `tools/tina4pascal` and its MCP tool, never a raw `fpc`/`xvfb`
one-off — the CLI and the MCP move in lockstep.

## Item 1 — blend modes through the shared `BlendRGB`

**The change under test.** Replace the shell-local `BlendRGB`
(`Tina4ShellLinux.pas:203`) with a call into `Tina4RenderBackend.BlendRGB`,
converting at the boundary (the shell packs `0xRRGGBB`; the shared routine takes
premultiplied-aware component floats and a mode string). Pass the real
`mix-blend-mode` / `background-blend-mode` string through instead of `''`. The
same edit applies to `Tina4ShellWin.pas:868`.

**How it will be proven.**

- `tests/raster/blend.html` already isolates the separable and non-separable
  modes and has a golden. Render it on Linux, `convert` to PNG, diff against
  **both** the raster golden and headless Chrome. A pass is under the suite's
  threshold against both.
- Add a `background-blend-mode` page that stacks a colour over an image in
  `hue`, `saturation`, `color` and `luminosity` — the four the local routine
  cannot do today. Before the change it will diverge from Chrome; after, it
  matches. That divergence-then-match is the proof the shared routine is what
  paints.
- Keep the existing macOS gate green in the same run — the shared `BlendRGB` is
  the code the Cocoa path already uses, so nothing there should move.

**Done when** both pages match Chrome on Linux within threshold and the macOS
suite is unchanged, with a Linux golden checked in for `blend.html`.

## Item 2 — HiDPI / supersampling

**The change under test.** On start the shell will read the display DPI — the
`Xft.dpi` X resource first, then the RANDR reported millimetre size against the
pixel size — turn it into a density, and size the backing pixmap and every layer
buffer by it, handing the same density to the engine (which already takes one).
Text and vector edges then resolve at device resolution instead of being blown
up from a density-1 raster.

**How it will be proven.**

- Render a fixed page at density 1 and at density 2 into buffers of the matching
  pixel size. The density-2 buffer will be twice the width and height; downscaled
  back to density 1 it will carry cleaner edges than the density-1 render — a
  measurable drop in edge jaggedness on a diagonal or a glyph stem.
- Diff the density-2 render (at its true pixel size) against headless Chrome run
  with `--force-device-scale-factor=2`. They should track, where at density 1
  the Chrome-2 reference would be off by a clean factor of two.
- Guard the buffer sizing with an assertion so a later change that drops the
  density silently fails the gate rather than the eye.

**Done when** a density-2 snapshot matches Chrome-at-2 within threshold and the
edge-quality metric beats the density-1 baseline.

## Item 3 — `clip-path` under a transform (prerequisite, not a quick check)

There is nothing to diff on Linux yet, because the X11 canvas has no world
transform for a clip to fall out of step with. The honest path is:

1. Add an affine matrix to `TX11Canvas` — `Translate`/`Rotate`/`Scale` compose
   into it, and `DX`/`DY` (today just an origin subtract) run points through it.
   This is the same piece that would make CSS `transform` and the new
   `writing-mode` rotation paint rotated on Linux rather than upright, so it pays
   for itself beyond this one item.
2. Only then run the clip points through the active matrix before building the
   `XSetClipRectangles` region (a rectangle clip cannot follow a rotation, so a
   rotated clip needs a mask via `XSetClipMask`, the harder half).
3. The Windows counterpart (`Tina4ShellWin.pas:771`) already has a CTM; there
   the fix is only to transform the clip points, and it can be proven on Linux's
   sibling GDI path or on Windows directly.

Until step 1 lands, this item stays open with its reason recorded, not marked
done. The reftest, once it is reachable, is a rotated box with `overflow:hidden`
and a child that overflows — the child must be clipped along the **rotated**
edge, which a device-space rectangle clip visibly fails.

## Folding Linux into the gate

The macOS harness compares a Cocoa `--snapshot` PNG against a Chrome PNG at a
threshold. A Linux mode does the same with two swaps: the snapshot comes from
`tools/tina4pascal screenshot linux` (the Xlib shell under `Xvfb`, BMP → PNG),
and the run is gated behind a `TINA4_LINUX=1` (or a `--target linux`) switch so
it only fires where an X server exists. The reftests and raster pages are shared
HTML — the same `examples/compliance/` and `tests/raster/` inputs feed both — so
a Linux regression reddens the same page names a developer already knows.

A container recipe (Debian + `fpc` + `xvfb` + `imagemagick`, repo mounted,
`build → xvfb-run snapshot → diff`) makes this a single command from the Mac and
gives the next person the identical run. That container is the deliverable that
turns "verified on my Linux box once" into a repeatable check.

## Scope, honestly

- Items 1 and 2 are finishable and automatable on Linux with the snapshot hook
  in place; item 1 is the clear first win because the shared code already exists
  and is proven on macOS.
- Item 3 is a Windows-shaped item that needs a Linux affine-transform
  prerequisite; it is recorded here so it is not silently dropped, but it is not
  a quick diff.
- The pure-raster (watch/Android) blend and clip paths are already guarded by
  `tests/raster/*` goldens on this Mac and are out of scope for this Linux plan.
