# Release notes

Development snapshots, newest first. Not a shipped release - these track what
landed on a branch before it merged.

## Unreleased — `feature/capture-stack-1` (2026-09-15)

Headline: the Tina4 engine now renders HTML natively on the **Apple Watch** and
Wear OS, the pure-Pascal rasterizer draws **real text and images**, and the stack
gained **notifications** (local + remote) and a **capture** element - all without
bloating the compile size.

### Apple Watch & Wear OS
- **`build watchsim` / `deploy watchsim`** — compile the engine to
  `libtina4watch.a` for the watchOS Simulator and run a native SwiftUI host that
  renders HTML on the watch (via the pure-Pascal `Tina4RasterCanvas`).
- **Patched FPC with a real `aarch64-watchossim` target** — built and tested; a
  Pascal program runs on the watch sim. Diff + apply script in
  `docs/fpc-watchossim.diff` / `docs/fpc-watchos-patch.md`.
- **Model B — engine on the paired iPhone, watch displays over
  WatchConnectivity.** Shippable, network-independent (no Wi-Fi, no server); the
  iPhone runs `libtina4watch-ios.a` and streams frames, taps flow back. Verified
  on an iPhone 12 Pro + Apple Watch Series 7. See `watch/modelb/`.
- **Raster mirror** — the same engine frames on a physical watch today via a Mac
  render server (`examples/watch/watch_server_raster.py` + `watchrender`).
- **Wear OS build** (`build wear` / `deploy wear`) — the engine runs natively on
  a Wear OS watch as `libtina4.so`.

### iOS Simulator (no physical iPhone)
- **The engine runs on the iOS Simulator as a native arm64 binary.** FPC 3.2.2
  has no simulator target, so the patched trunk compiler (the one built for the
  watch, `~/fpc-watchos`) is used with its upstream `iphonesim` target. The
  `aarch64-iphonesim` RTL is built (133 units) and `ios/build-sim.sh` compiles
  `libtina4iossim.a`; `ios/sim/` is a SwiftUI host that renders HTML on the
  Simulator. A Pascal `writeln` and the full engine both verified running under
  `simctl` — no device, no signing. Renders through the pure-Pascal rasterizer
  (`Tina4RasterCanvas`); native Core Graphics on the sim (`univint`) is the
  follow-up. See `docs/fpc-iphonesim.md`.

### Native raster rendering (Android + watch path)
- **Text.** `Tina4RasterCanvas.DrawText` was a no-op; it now draws a **7-segment
  numeric font** (`0-9 : . -`) and a **stroke vector font** for **A–Z and a–z**
  (distinct lowercase with x-height, ascenders, descenders) plus common
  punctuation - all resolution-independent.
- **Rounded rectangles.** `FillRoundRect`/`StrokeRoundRect` now round on the
  raster path (was square); corner tessellation is adaptive so full circles
  aren't faceted. Fixes `border-radius` on the watch **and** Android.
- **Images.** WebP (`<img>`, data URI or file) decodes and blits through the
  pure-Pascal path.

### Notifications
- **Local** — `notify.show('Title','Body')` fires a real OS notification on
  **macOS, iOS and Android** (was macOS-only), through the `Tina4Notify` shell
  hook. iOS local notifications forward to a paired Apple Watch.
- **iOS remote (APNs)** — the app registers for remote notifications and hands
  the device token to the engine (`Tina4PushToken`); your server talks straight
  to APNs with the `.p8`, no third party. Zero size cost.
- **Android remote, self-hosted** — a foreground service long-polls the Tina4
  backend and posts notifications; **~5.5 KB of Java, `libtina4.so` unchanged**.
  No Google, no library. FCM stays an opt-in `.aar` for apps that accept its
  several-megabyte weight.

### Capture stack
- **`<camera-view>`** element + a capture contract (audio-level metering, camera
  preview, background capture).
- **Real `AudioLevel` metering on macOS** (Core Audio) - the noise-detection
  keystone.
- **`<recorder>`** mic capture (macOS `AVAudioRecorder` → `.m4a`).

### FPC toolchain
- watchOS-Simulator target patch (Phase 1) - built, tested, documented.
- Phase 2 (physical watch, `arm64_32`): **M1 done** — the FPC-LLVM compiler
  builds and runs on this host; **M2 crux pinned** — aarch64 pointer size is
  compile-time, so ILP32 needs a separate CPU variant (`docs/FPC-WATCHOS-PLAN.md`).

### Testing
- **New: raster golden-image harness** (`tools/run-raster-tests.sh`) - covers the
  software rasterizer (fonts, rounded fills, gradients, WebP) that the Cocoa
  reftests never touched. 6/6 green.
- W3C reftests **148/148** and the five unit suites (`test_dom`, `test_interact`,
  `test_pseudo_rebuild`, `test_elements`, `test_metrics`) all green.

### Fixes
- Absolutely- and block-positioned `<img>` / `<svg>` / `<qrcode>` now load and
  paint their image (they went through `LayoutBlock`, which never called
  `MakeReplacedBox`) - fixed on every platform.
