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
(Windows/Linux) and pure-raster (Android/watch) gaps. These can't be proven from
a macOS `--snapshot` (it always takes the Cocoa path) — **`docs/CATEGORY-A-LINUX-TESTING.md`**
is the concrete plan to verify the three remaining items on Linux/Xlib (build,
`Xvfb` snapshot via `LinSaveBmp`, per-item diff-vs-Chrome, gate integration).

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
- **[M mostly done] CSS filters / `backdrop-filter` / 3D on raster** — the CSS
  **`filter` chain now runs on the raster path**: `Tina4RasterCanvas.EndLayerFiltered`
  converts the layer to premultiplied floats, runs the shared
  `Tina4Compositor.ApplyFilterChainF` (blur, brightness, contrast, grayscale, sepia,
  invert, saturate, hue-rotate, opacity, drop-shadow) and unpremultiplies back —
  the same code the native shells use. Guarded by `tests/raster/filter.html`.
  **`backdrop-filter` also done on raster** — the canvas reads its own painted
  pixels under the rect, filters them and writes them back
  (`tests/raster/backdrop.html`). *Remaining on raster:* only 3D-quad mapping
  (`EndLayer3D`), which is niche.

## B. Text & internationalization
Nearly all of B is done: `hyphens: manual`, `font-variant: small-caps`, `ruby`,
`font-stretch`, **bidi** (line-level UBA reorder, mirrored punctuation,
`<bdo>`/`<bdi>`, **per-character direction within a token** via the shaping
backend), and **`writing-mode: vertical-rl` *and* `vertical-lr`** (real column
block-flow, both directions). What remains is data-dependent or niche —
`hyphens: auto` (needs a hyphenation dictionary), upright CJK orientation
(`text-orientation: upright`), a vertical block without a definite height, the
*embedding effect* of the `unicode-bidi` control codes, and accents/CJK on the
pure-raster stroke font — left honestly open rather than shipped as a
low-quality hack.

- **[L → mostly done] Bidi / RTL** — **line-level UBA reordering DONE.** Mixed
  LTR/RTL lines are reordered logical→visual by the Unicode Bidi Algorithm L2 rule
  (Hebrew/Arabic classification, base level from `direction` / the `dir` attribute /
  `dir="auto"` first-strong detection, simplified N1/N2 neutral resolution, space
  re-derivation for reversed runs) — verified pixel-matching Chrome on Hebrew+English
  paragraphs. **Mirrored punctuation done** (UBA L4: a pure-punctuation token that
  resolves to an RTL level paints reversed + mirrored — `(`↔`)`, `[`↔`]`, `<`↔`>`,
  guillemets, etc.; strong-char runs are left to the backend to avoid double
  mirroring). Native backends shape each run. Reftest `bidi-rtl-ltr`. The invisible
  `unicode-bidi` control characters (LRM/RLM/ALM, LRE/RLE/PDF/LRO/RLO,
  LRI/RLI/FSI/PDI) are stripped so they never tofu (`StripBidiControls`).
  **Per-character direction within one token DONE on the native path** — a token
  that mixes scripts (e.g. `abc99שלום`) is one shaped run, so Core Text / the
  native backend resolves its internal bidi and it pixel-matches Chrome. **Remaining:**
  the *embedding effect* of those control codes (not just their glyphs), and RTL
  shaping on the pure-raster path (no shaper — the watch/Android stroke font).
  (`<bdi>`/`<bdo>` elements DONE.)
- ~~**[L] `writing-mode` (full vertical block-flow)**~~ — **DONE for `vertical-rl`
  *and* `vertical-lr`** with a definite height: the inline content lays out against
  the height (wrapping into columns) and paints 90° CW — top-to-bottom runs,
  CW-rotated Latin glyphs, upright box background/border. `vertical-rl` fills
  right-to-left columns; `vertical-lr` reverses the column order in layout
  (`ReverseVColumns` reflects each line box about the content centre, half-leading
  preserved) so the same rotation fills left-to-right columns. Both verified
  matching Chrome (`vertical-rl` 1.83%, `vertical-lr` 5.16% raw / sub-pixel once
  aligned); gated so horizontal layout is untouched (156/156, reftests
  `writing-mode-vertical` + `writing-mode-vertical-lr`). **Remaining:** a vertical
  block without a definite height (still the flat single-line fallback), and
  upright CJK glyph orientation (`text-orientation: upright`).
- **[S] `font-stretch`** — **DONE (synthetic).** Keywords + `<percentage>` parse to
  a factor; the run advance is scaled to match and the glyphs paint through a
  horizontal `Scale`. Carried as a `Styles` marker (no per-run field) and bucketed
  (condensed 0.78× / expanded 1.28×) so measure and paint always agree. Reftest
  `font-stretch`. Not width-variant face selection (that needs the faces).
- ~~**[M] `hyphens`**~~ — **DONE (manual).** `manual` (the CSS default) breaks a
  word at its soft hyphens (`&shy;`/U+00AD) when a line needs it and renders a `-`;
  `none` never breaks there; `auto` degrades to `manual` (no dictionary). Added the
  `&shy;` entity. Reftest `hyphens-shy`. Remaining: `auto` dictionary hyphenation.
- **[S] `font-variant: small-caps`** — **DONE** (synthesised: lowercase → 0.78×
  uppercase on the shared baseline, one atomic run; reftest `font-smallcaps`).
  Remaining: non-ASCII lowercase casing.
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
- **[M mostly done] SVG** — shapes/paths **and fill gradients** now:
  `<linearGradient>`/`<radialGradient>` via `fill="url(#id)"`, `<stop>`
  offset/stop-color/stop-opacity, objectBoundingBox (default) + userSpaceOnUse,
  painted through the shared `FillLinearGradient`/`FillRadialGradient` clipped to
  the shape (real polygon clip on Cocoa/iOS). Reftests `svg-linear-gradient` +
  `svg-radial-gradient` (both delta 0.00% vs the CSS-gradient ref), verified
  matching Chrome (3.34%). **`clip-path="url(#id)"` also done** — clips an element
  or a `<g>` subtree to a `<clipPath>`'s first shape (userSpaceOnUse) via the
  polygon clip; reftest `svg-clip-path` (delta 0.00%), verified 0.00% vs Chrome
  on a circle-clipped rect + a rect-clipped group. **`<use href="#id" x y>` also done** — re-paints a referenced
  element (incl. from `<defs>`), translated, inheriting the use's presentation,
  cycle-guarded; reftest `svg-use` (delta 0.00%). Remaining: `gradientTransform`,
  `spreadMethod`, `href` stop-inheritance, gradient *strokes*, multi-shape/
  objectBoundingBox clipPaths, mask, filters, patterns, `<use>` width/height.
- **[S] Lottie** — no gradient support.
- ~~**[S] Canvas2D image transforms**~~ — **DONE.** `drawImage` now honours the
  2D context matrix: an axis-aligned matrix (translate + scale, incl. flip) maps
  both corners through the CTM so the drawn size follows `ctx.scale` on every
  backend; rotation/skew draw through the full user→device matrix
  (`TransformMatrix`, honoured on Cocoa/iOS — degrades to axis-aligned where the
  shell has no device transform, same as CSS transforms there). Verified via a
  runtime Cocoa snapshot (natural / 1.5× scaled / 35°-rotated all correct).
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
- The remaining fidelity items in **A** (desktop blend modes → shared `BlendRGB`,
  HiDPI, clip-path/transform) have no tests on the Linux/Windows path — the plan
  to close that is `docs/CATEGORY-A-LINUX-TESTING.md`.
- All shell code (Swift / Objective-C / Java) is device- and build-verified only.
