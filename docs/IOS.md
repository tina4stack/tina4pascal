# Tina4Pascal on iOS

The same shared engine that drives Android (`src/Tina4Interact.pas`) drives iOS
too. Only the *shell* differs: on iOS the `TTina4Canvas` contract is implemented
on Apple's C graphics stack — **Core Graphics** for shapes/images and **Core
Text** for glyphs — via FPC's `univint` bindings, so there is **no
Objective‑Pascal and no UIKit binding** on the Pascal side. A thin Objective‑C
`UIView` hosts the engine and forwards touches / keys.

```
Tina4Interact (portable engine)      ← identical to Android
   │  TTina4Canvas contract
   ▼
Tina4ShellIOS.TIOSCanvas             ← Core Graphics + Core Text (univint)
   │  tina4_* C ABI
   ▼
ios/tina4ios.pas  →  libtina4ios.a   ← static lib, linked by Xcode
   │
   ▼
ios/app/*.m (Obj‑C)  →  Tina4Pascal.app
```

**Shipping size: ~1.5 MB** for the whole Release app (single binary — the full
HTML/CSS layout engine, QR, SVG, the Core Text canvas and the Obj‑C host,
statically linked). Debug builds look tiny (~100 KB main) because Xcode splits
the code into a separate `.debug.dylib`; always measure Release.

## Toolchain

Uses the same self‑contained FPC 3.2.2 at `~/fpc` as every other target. iOS
device is `-Tios -Paarch64`. Everything Core Graphics / Core Text / Core
Foundation / Image I/O is already bundled as precompiled `univint` units for
`aarch64-ios` — no headers to translate:

| Need | univint unit(s) |
|---|---|
| Context, shapes, images | `CGContext`, `CGColor`, `CGColorSpace`, `CGGeometry`, `CGImage` |
| Rounded rects / paths | drawn with `CGContextAddArcToPoint` (no `CGPath` object needed) |
| Text | `CTFont`, `CTLine`, `CTStringAttributes` |
| Attributed strings | `CFString`, `CFAttributedString`, `CFDictionary` |
| Load an image file | `CGImageSource` + `CFURL` |

## Build recipe

```sh
# 1. Pascal → static library (engine + Core Text canvas)
./ios/build.sh                 # FPC -Tios -Paarch64 -Cn, then libtool the
                               # objects from FPC's linkfiles*.res → app/libtina4ios.a

# 2. Xcode project from the spec (one‑time: brew install xcodegen)
cd ios && xcodegen             # writes Tina4Pascal.xcodeproj from project.yml

# 3. Build + sign + (optionally) install
xcodebuild -project Tina4Pascal.xcodeproj -scheme Tina4Pascal \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> \
  <DerivedData>/Build/Products/Debug-iphoneos/Tina4Pascal.app
```

`ios/build.sh` is the crucial bit: FPC can't emit a static lib directly, so we
compile with `-Cn` (skip FPC's own link — it would try to build a full
executable and fail) and then `libtool -static` **every** object FPC listed in
the generated `linkfiles*.res` (ours + the FPC RTL + univint) into one archive.

## Learnings (the non‑obvious bits)

1. **Runtime init.** A `library` archive exports `PASCALMAIN`; the Obj‑C
   `main()` must call it **once** before UIKit starts, or the FPC heap /
   exceptions / string code are uninitialised and the first allocation crashes.
2. **Coordinates.** A `UIView`'s `drawRect:` context is already **top‑left /
   y‑down** and in **points** (UIKit scales for retina). That matches the
   engine's CSS‑px space, so the shell runs at **density 1** and passes the
   view's point size — do **not** multiply by `contentScaleFactor`.
3. **Two APIs still need a local vertical flip** inside that y‑down context:
   Core Text (`CTLineDraw`) and `CGContextDrawImage`. Wrap each in
   save / translate to baseline (or `y+h`) / `scale(1,-1)` / draw / restore.
4. **`-Cn` then `libtool`**, not FPC linking. FPC's link step targets a full
   binary; let Xcode do the final link so it owns signing + frameworks.
5. **Static‑lib symbols must be reachable.** The `tina4_*` functions are in an
   `exports` clause; they’re called from Obj‑C, so the linker keeps them and
   everything they pull in (the whole engine). No `-force_load` needed.
6. **Frameworks to link** (in `project.yml`): `CoreGraphics`, `CoreText`,
   `CoreFoundation`, `ImageIO`, `MobileCoreServices`, plus the implicit
   `Foundation` / `UIKit`. FPC only auto‑records `Foundation`.
7. **`install` needs the device unlocked** — a locked phone fails with
   `kAMDMobileImageMounterDeviceLocked`. First run also needs the user to trust
   the developer cert in Settings › General › VPN & Device Management.
8. **Type friction with univint:** `CGMutablePathRef`/`CFMutableAttributedStringRef`
   need an explicit cast to their non‑mutable base for some calls;
   `CFURLCreateFromFileSystemRepresentation` takes a `PChar`, not `PByte`.

## The CLI does the heavy lifting

`tools/tina4pascal` wraps the whole loop so you don't retype the commands:

```sh
tina4pascal setup ios            # xcodegen + libimobiledevice + pymobiledevice3
                                 # (Xcode itself is a manual App Store install)
tina4pascal doctor               # reports Xcode / xcodegen / device / screenshots
tina4pascal ios                  # engine → xcodegen → xcodebuild (sign) → install → launch
tina4pascal screenshot shot.png ios   # live screen grab from the iPhone
```

**Screenshotting a physical iPhone (iOS 17+).** The classic libimobiledevice
`screenshotr` service can't see the CoreDevice-mounted developer image, so use
`pymobiledevice3`, which opens the iOS 17+ native tunnel itself:

```sh
pymobiledevice3 developer dvt screenshot out.png   # phone must be UNLOCKED
```

That is exactly what `tina4pascal screenshot out.png ios` runs. `setup ios`
installs it (via pipx) alongside `idevice_id` (device listing) and `xcodegen`.

## Permissions (both platforms)

Interaction that touches hardware or private data needs a declared permission —
and, on modern OSes, a **runtime** grant. The engine stays permission‑free; each
shell declares and requests.

| Capability | iOS | Android |
|---|---|---|
| **Camera** (`<camera>`) | `NSCameraUsageDescription` in `Info.plist` (present). Capture via `UIImagePickerController` prompts for access on first use. | Capturing via the camera **app** (`ACTION_IMAGE_CAPTURE` through a chooser) needs **no** declared permission. Only declare `android.permission.CAMERA` if you open the camera *in‑process*; declaring it then forces a runtime `requestPermissions` on API 23+. |
| **File / media pick** (`<input type=file>`) | `UIDocumentPickerViewController` — no permission needed (user picks the file). | Storage Access Framework (`ACTION_GET_CONTENT`) — no permission needed. |
| **Photo library save** | add `NSPhotoLibraryAddUsageDescription` if you later save the shot to the library. | scoped storage / `MediaStore` — no legacy `WRITE_EXTERNAL_STORAGE` on API 29+. |

Rule of thumb: prefer the **system picker / capture UI** (out‑of‑process) over
in‑process hardware access — it needs no runtime permission and is what both
shells do today. When the CLI scaffolds a new capability it should add the iOS
usage string and, only if in‑process, the Android `<uses-permission>` + a
runtime request.

## Shipping additional libraries

The build is designed to absorb extra native code without changing the app
plumbing:

- **More Pascal / FPC packages.** Just `uses` the unit; `ios/build.sh` archives
  whatever FPC lists in `linkfiles*.res`, so new dependencies flow into
  `libtina4ios.a` automatically. On Android they compile straight into
  `libtina4.so`.
- **An Apple framework** (e.g. `AVFoundation` for live camera, `PDFKit`): add it
  to `dependencies:` in `ios/project.yml` and `uses` its `univint` unit.
- **A third‑party C/static lib**: drop the `.a`/`.o` in `ios/app`, add
  `-l<name>` to `OTHER_LDFLAGS`; on Android put the `.so` in
  `app/src/main/jniLibs/<abi>/` and `System.loadLibrary("<name>")` (or declare
  it in the Pascal `external`).
- **Keep the core clean.** Extra libraries belong in a *shell* or a new contract
  method with a safe default — never an `{$ifdef ios}` inside `src/Tina4*Dom/
  Layout/Interact`. That is what keeps one engine building for five OSes.
