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

- **[M] Advanced blend modes** — `color-dodge`/`color-burn` and the non-separable
  `hue`/`saturation`/`color`/`luminosity` fall back to source-over in the Win/Linux
  `BlendPixel` (`Tina4ShellWin.pas:868`); `Tina4RasterCanvas.BlendPixel` has no CSS
  blend modes at all. Dodge/burn are per-channel; the four non-separable ones need
  the CSS set (SetLum / SetSat / ClipColor).
- **[L] HiDPI** — shells run at density 1, no supersampling (`Tina4ShellWin.pas:828`,
  `Tina4ShellIOS.pas:14`). Engine already takes a density arg; read per-monitor DPI
  and size layer buffers to match.
- **[S] `clip-path` under a transform (Windows)** — GDI clip is device-space and
  ignores the world transform (`Tina4ShellWin.pas:771`). Run the clip points through
  the active CTM before building the region.
- **[M] Rounded clipping on raster** — `ClipRoundRect` degrades to a rectangular
  clip, so `overflow:hidden` + `border-radius` clips square on watch/Android.
- **[M] CSS filters / `backdrop-filter` / 3D on raster** — `BeginLayer` /
  `EndLayerFiltered` are no-ops on the raster canvas.

## B. Text & internationalization
- **[L] Bidi / RTL** — `direction` is block-level only; `bdi`/`bdo` + full
  mixed-direction bidi not done (engine is LTR).
- **[M] `writing-mode`** — single sideways line only, no full vertical block-flow.
- **[M] `hyphens`** — `manual`/`auto` hyphenation not done.
- **[S] `font-variant` small-caps, `font-stretch`** — parsed-ignored.
- **[M] `ruby`** — inline only, no stacked CJK annotation.
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
- **[M] iOS Simulator** — **← first pick.** FPC 3.2.2 has **no** simulator target;
  the patched **trunk (3.3.1)** compiler at `~/fpc-watchos/bin/ppca64` already
  advertises `iPhoneSim` (same tree that gained `watchOSSim`). iOS device and sim
  are both arm64 LP64, so no ABI/compiler work — this is the watchossim playbook:
  build the `aarch64-iphonesim` RTL, compile `libtina4ios-sim.a`, wire
  `deploy ios-sim` (build app against `iPhoneSimulator.sdk` → `xcrun simctl` install
  + launch). SDK (iPhoneSimulator26.5) and `simctl` are present on this host.
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
