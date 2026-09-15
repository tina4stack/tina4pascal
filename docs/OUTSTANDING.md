# Outstanding work — gap register

The core is strong: **CSS 105 ✅ / 6 🟡 / 3 📦 / 0 ❌**, HTML nearly all ✅, W3C
reftests 148/148, five unit suites + the raster golden suite green. What remains
is the **advanced tail** of otherwise-working features and the **per-shell** work.

Source of truth for CSS/HTML coverage stays `docs/CSS-PROPERTY-INDEX.md` and
`docs/HTML-ELEMENT-INDEX.md`; this file tracks the cross-cutting gaps and the
platform/toolchain work those indexes don't capture. Keep it honest — move an
item out only with proof (a test, a reftest, or a verified device run).

Effort key: **S** small · **M** medium · **L** large.

## A. Rendering fidelity — software / raster path
macOS + iOS (CoreGraphics) are complete here; these are the software compositor
(Windows/Linux) and pure-raster (Android/watch) gaps.

- ~~**[M] Advanced blend modes**~~ — **DONE (raster + shared).** The shared
  `BlendRGB` (`Tina4RenderBackend`) now covers all separable modes (dodge/burn
  included) **and** the four non-separable ones (`hue`/`saturation`/`color`/
  `luminosity`) via the CSS `Lum`/`Sat`/`SetLum`/`SetSat`/`ClipColor` set — so
  `background-blend-mode` gets them everywhere. `mix-blend-mode` now composites on
  the **raster** path too: `Tina4RasterCanvas` implements `BeginLayer`/
  `EndLayerFiltered` (offscreen buffer → composite back with `BlendRGB`). Guarded
  by `tests/raster/blend.html`. *Remaining:* the Win/Linux `BlendPixel`
  (`Tina4ShellWin.pas`) should route through the shared `BlendRGB` rather than its
  own partial set.
- **[L] HiDPI** — shells run at density 1, no supersampling (`Tina4ShellWin.pas:828`,
  `Tina4ShellIOS.pas:14`). Engine already takes a density arg; read per-monitor DPI
  and size layer buffers to match.
- **[S] `clip-path` under a transform (Windows)** — GDI clip is device-space and
  ignores the world transform (`Tina4ShellWin.pas:771`). Run the clip points through
  the active CTM before building the region.
- ~~**[M] Rounded clipping on raster**~~ — **DONE.** `Tina4RasterCanvas` now keeps
  a clip stack tested per-pixel in `BlendPixel` (rect + rounded corners), so
  `overflow:hidden` + `border-radius` clips round on watch/Android. Near-zero cost
  when unclipped (empty stack). Guarded by `tests/raster/clip.html` (golden) and
  the `clip-roundrect` reftest pair.
- **[M] CSS filters / `backdrop-filter` / 3D on raster** — `BeginLayer` /
  `EndLayerFiltered` now composite for `mix-blend-mode`, but the `filter` chain,
  `backdrop-filter` and 3D-quad mapping on the layer are still skipped (safe
  degrade) on the raster canvas.

## B. Text & internationalization
- **[L] Bidi / RTL** — `direction` is block-level only; `bdi`/`bdo` + full
  mixed-direction bidi not done (engine is LTR).
- **[M] `writing-mode`** — single sideways line only, no full vertical block-flow.
- ~~**[M] `hyphens`**~~ — **DONE (manual).** `manual` (the CSS default) breaks a
  word at its soft hyphens (`&shy;`/U+00AD) when a line needs it and renders a `-`;
  `none` never breaks there; `auto` degrades to `manual` (no dictionary). Added the
  `&shy;` entity. Reftest `hyphens-shy`. Remaining: `auto` dictionary hyphenation.
- **[S] `font-variant: small-caps`** — **DONE** (synthesised: lowercase → 0.78×
  uppercase on the shared baseline, one atomic run; reftest `font-smallcaps`).
  Remaining: `font-stretch` (width-variant selection / synthetic stretch);
  non-ASCII lowercase casing for small-caps.
- ~~**[M] `ruby`**~~ — **DONE.** `<rt>` renders centred above its base in a smaller
  font (furigana); the ruby is an atomic inline box that reserves space above the
  line; `<rp>` hidden. One base+annotation pair per ruby (no per-character split).
  Reftest `ruby-basic`.
- **[M] Raster fonts (watch/Android)** — digits + A–Z/a–z + basic punctuation;
  no accents/CJK, no kerning.

## C. Images & media
- **[M] WebP VP8 (lossy)** — only VP8L (lossless) decodes; Win/Linux `DrawRGBA`
  for WebP still TODO.
- **[L] PNG/JPEG on the raster path** — not decoded (needs a native shell or a
  pure-Pascal decoder) — the watch/headless gap.
- **[M] SVG** — basic shapes/paths only; gradients, clip/mask, filters not done.
- **[S] Lottie** — no gradient support.
- **[S] Canvas2D** — image draw axis-aligned only (rotate/scale TODO).
- **[S] `<video>` (macOS)** — `AVPlayerView` loop TODO + GUI-run verify pending.

## D. Capture stack (per-shell)
- **[M] `<recorder>`** — macOS ✅; iOS (`AVAudioRecorder`+`AVAudioSession`) /
  Android (`MediaRecorder`+`RECORD_AUDIO`) shell overrides are the follow-up.
- **[M] `<camera-view>` preview** — core box + contract done; native preview +
  frame grab per-shell (❌ everywhere).
- **[M] `<barcode-scanner>` camera** — decode done (libzbar, desktop); camera
  preview/capture per-shell (❌).

## E. Notifications
- **[M] Android FCM** `.aar` — designed, not built (opt-in, to keep size lean).
- **[S] End-to-end wiring** — self-hosted poll endpoint stub + a signed iOS
  device install with Push enabled on the App ID.

## F. Platform & toolchain
- **[✅ DONE — native] iOS Simulator** — the engine runs on the iOS Simulator with
  its **native Core Graphics / Core Text** canvas (`Tina4ShellIOS`),
  device-identical, no physical iPhone. `aarch64-iphonesim` RTL (133 units) +
  `univint` (~40 CF/CG/CT units, built `-Mmacpas`) installed at
  `~/fpc-watchos/units/aarch64-iphonesim`; `ios/build-sim.sh` (default `--native`,
  `--raster` fallback) → `libtina4iossim.a`; `ios/sim/` app verified rendering on
  the Simulator (`docs/fpc-iphonesim.md`). **Remaining, minor:**
  (a) wire `build ios-sim` / `deploy ios-sim` into `tools/tina4pascal` + the MCP
  (currently the standalone `ios/build-sim.sh`) — held only by a concurrent edit
  on that file; (b) **`<img>` works — bundled *and* remote** (bundled decoded off the app
  bundle; remote downloaded over NSURLSession via `ios/sim/App/ImageLoader.m`,
  then `tina4_image_ready` relayout → decode, verified cold-load on the sim);
  (c) **upstream MR ready** — the
  `t_darwin.pas` one-liner (`docs/fpc-iphonesim-linker.diff`, verified: patched
  compiler direct-links `fpc -Tiphonesim` and runs in the sim) awaits submission
  as a GitLab merge request. Reproducible build: `tools/build-iphonesim-toolchain.sh`.
- **[M] Android emulator** — needs the Android SDK + `adb` + an **arm64** system
  image installed first (none on this host today); the arm64 `.so` then runs on an
  Apple-Silicon emulator and the CLI wires `deploy`/input to it. Not a free win
  until the SDK is in place.
- **[L] Physical Apple Watch (`arm64_32`)** — FPC Phase 2. M1 done (FPC-LLVM builds);
  M2 crux pinned (compile-time pointer size → a separate ILP32 CPU variant).
  `docs/FPC-WATCHOS-PLAN.md`.
- **[M] Intel macOS** — broken on FPC 3.2.2; fixed in trunk (the patched watchOS
  compiler is 3.3.1 trunk, so a path exists).

## G. Performance
- **[M] Android JNI cost** — pure-Pascal `Tina4RasterCanvas` + one `DrawRGBA` blit
  is the fix; the backing-store is still TODO.

## H. Interaction model
- **[M] `user-select` / `resize`** — parsed-ignored (no selection model / resize).
- **[L] Shadow DOM / `<slot>`** — passthrough only.

## Testing gaps
- The three fidelity items in **A** (blend modes, HiDPI, clip-path/transform) have
  no tests.
- All shell code (Swift / Objective-C / Java) is device- and build-verified only.
