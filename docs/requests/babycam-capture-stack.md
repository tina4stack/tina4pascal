# Request: live capture stack (camera preview + audio level + background) across all shells

**Status:** proposed
**Driver:** BabyCam app (any device ↔ any device: iPhone/iPad/Android as Monitor or Viewer)
**Scope:** Monitor-side *capture* primitives that are needed under **any** transport.
Transport/streaming and Viewer playback are deliberately **out of scope here** (the
Viewer already plays live HLS via the native `<video>` overlay; the produce/stream
sink is a follow-on request once the app's transport ADR lands).

## Why now
The engine already covers the Viewer half — native `<video>` (iOS
`AVPlayerViewController`, Android `VideoView`, macOS `AVPlayerView`), `<barcode-scanner>`
live camera preview + QR, `Notify`, `Tina4WebSocket`. What's missing is the ability to
**produce**: a live camera preview you can pull frames from, a continuous microphone
**level** (for noise detection), that same capture running while backgrounded, and mic
capture proven on the phones (only macOS is proven today). These are general-purpose
capture capabilities, not babycam-specific.

## Non-goals
- **No transport / encoder / stream server** — separate request after the transport ADR.
- **No watchOS** — FPC 3.2.2 has no watchOS slice; the Watch is an APNs alert surface, not a build target. Do not add a target.
- **No mocks** — hardware capture is proven by a real on-device run + screenshot, never a stub.

## Three-layer compliance
Every item is a **new virtual on `Tina4RenderBackend` with a safe default**, so the
headless path and every existing shell keep compiling and running unchanged. Core stays
OS-free; all OS calls live in the shells.

---

## E1 — Continuous microphone level (keystone)
A cheap meter, decoupled from the record-to-file `<recorder>` path, so noise detection
can run without writing a file.

**Contract (`src/Tina4RenderBackend.pas`):**
```pascal
{ Arm the mic purely for metering (no file). True if it started (mic present +
  permission granted). Cheap counterpart to StartAudioCapture. Default False. }
function StartAudioMeter: Boolean; virtual;
{ Stop metering. Default no-op. }
procedure StopAudioMeter; virtual;
{ Current input level as RMS 0.0..1.0 (0 = silence, 1 = full-scale). Valid only
  while metering (or StartAudioCapture) is armed. Default 0.0 — a shell with no
  audio-in reads permanent silence and callers degrade cleanly. }
function AudioLevel: Single; virtual;
```

**Shells:** Cocoa (AVAudioEngine input tap RMS, or AVAudioRecorder `.meteringEnabled` +
`averagePower`), iOS (same, AVAudioSession `playAndRecord`), Android (`AudioRecord` +
short-window RMS), Win (WASAPI capture), Linux (ALSA/PulseAudio capture).

**Permissions:** iOS/macOS `NSMicrophoneUsageDescription`; Android `RECORD_AUDIO`.

**Proof:** `test_dom` still green (defaults compile). On-device: a test page shows a live
level bar driven by `AudioLevel`; clap → bar jumps. Screenshot on iPhone + Android.

## E2 — Live camera preview element `<camera-view>` + frame grab
Generalize the `<barcode-scanner>` session into a plain preview with no QR decode, and
expose frames for streaming/motion.

**Contract:**
```pascal
{ Start a live camera preview overlaid on element ElementId's layout box (same
  overlay model as <video>). Facing = 'front' | 'back'. True if the camera
  started. Default False. }
function StartCameraPreview(const ElementId, Facing: string): Boolean; virtual;
{ Stop and remove the preview. Default no-op. }
procedure StopCameraPreview(const ElementId: string); virtual;
{ Most recent preview frame as JPEG bytes (for streaming / motion / detection),
  or nil if none available. Non-blocking. Default nil. }
function GrabCameraFrame(const ElementId: string): TBytes; virtual;
```

**Core/DOM:** add `<camera-view>` as a replaced, inline-atomic element (mirror `<video>`
in `Tina4HTMLDom`/`Tina4HTMLLayout`): a placeholder box the shell overlays. Add a
reftest pair (`camera-view-test.html` / `-ref.html`, the ref draws the placeholder box
from primitives) and update `docs/HTML-ELEMENT-INDEX.md`.

**Shells:** iOS/Cocoa — reuse the scanner's `AVCaptureSession` + `AVCaptureVideoPreviewLayer`
minus the metadata output; add `AVCaptureVideoDataOutput` for `GrabCameraFrame` (JPEG).
Android — Camera2 preview `SurfaceView` sibling (like the scanner) + `ImageReader` JPEG.
Win — MediaFoundation source reader. Linux — V4L2 `MJPG`/`YUYV`. macOS `CaptureCamera`
(still-photo) is currently stubbed — this item lands the real macOS camera session it
refers to.

**Proof:** reftest pair green in `run-compliance.sh`; on-device preview visible +
`GrabCameraFrame` returns non-empty JPEG. Screenshot on iPhone + Android + macOS.

## E3 — Mobile mic capture parity (iOS + Android)
`StartAudioCapture` / `StopAudioCapture` (+ E1's meter) are proven only on macOS.
Implement on iOS (`AVAudioSession` + `AVAudioRecorder`/engine → m4a) and Android
(`MediaRecorder`/`AudioRecord`). Add `NSMicrophoneUsageDescription` to `ios/app/Info.plist`
and `RECORD_AUDIO` to `AndroidManifest.xml`.

**Proof:** `<recorder>` arms and returns a real file path on iPhone + Android; `AudioLevel`
non-zero while armed.

## E4 — Background capture (screen off / app backgrounded)
The Monitor must keep capturing when the phone is set down and locked.

**Contract:**
```pascal
{ Ask the OS to keep audio/camera capture alive while backgrounded/locked.
  Returns True if granted. Default True on desktop (no restriction), False where
  the OS declines. }
function BeginBackgroundCapture(const Reason: string): Boolean; virtual;
procedure EndBackgroundCapture; virtual;
```

**Shells:** iOS — `UIBackgroundModes: audio` in Info.plist + `AVAudioSession`
`playAndRecord`; keep the capture session alive. Android — start a **foreground service**
with an ongoing notification (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CAMERA/MICROPHONE`).
Desktop — no-op returning True.

**Proof:** on iPhone + Android, lock the screen with metering armed; `AudioLevel` keeps
updating (log the value); app not killed.

---

## Definition of done
- [ ] E1–E4 virtuals added to `Tina4RenderBackend` with safe defaults; `test_dom` prints
      `ALL TESTS PASS`, exit 0; `run-compliance.sh` 65/65 → 66/66 (with the `<camera-view>` reftest).
- [ ] `docs/HTML-ELEMENT-INDEX.md` row for `<camera-view>` added, in the same commit,
      with proof (reftest + on-device screenshot), status ✅ / 🟡 per the exact legend.
- [ ] Real on-device runs on **iPhone** (covers iPad) and **Android**; macOS for desktop
      Monitor. Win/Linux may land as 🟡 (link-checked) if hardware unavailable — state it.
- [ ] No `{$IFDEF OS}` in core; no OS unit imported into core; each shell change keeps its
      snapshot green (run `run-compliance.sh` after every shell edit — a shell regression
      silently reddens every snapshot).
- [ ] `leakcheck.pas` clean after the DOM/element lifetime changes.

## Verify
```sh
export PPC_CONFIG_PATH=$HOME/fpc/etc PATH=$HOME/fpc/bin:$PATH
cd tests && fpc -Mdelphi -Fu../src test_dom.pas && ./test_dom     # ALL TESTS PASS
../tools/run-compliance.sh                                        # reftests green
# device proof (needs TINA4_IOS_TEAM + paired iPhone / Android):
tools/tina4pascal debug ios       # preview + level bar, screenshot, tail log
tools/tina4pascal debug android
```
