# Tina4Pascal — Android shell

The Tina4 native renderer running on Android. Every pixel is drawn by the
Free Pascal core (`src/`) through `android.graphics.Canvas` over JNI — the
same architecture as the macOS Cocoa shell, just a different `TTina4Canvas`.

```
 Java Tina4View.onDraw(Canvas)
        │  JNI
        ▼
 libtina4.so  ── nativePaint(canvas,w,h) ──▶ TAndroidCanvas (JNI → Canvas/Paint/Path)
        │                                        ▲
        └─ parse HTML → layout → PaintBox ────────┘   (the portable core)
```

- `jni/tina4jni.pas` — JNI exports; hosts the app (parse → layout → paint).
- `src/Tina4ShellAndroid.pas` — `TAndroidCanvas`/`TAndroidShell` (in the repo `src/`).
- `app/` — a minimal Gradle app: one `Tina4View`, one `MainActivity`,
  `assets/index.html` as the document.

## Size

The whole engine is **~1.08 MB** (`libtina4.so`, arm64, stripped) — compresses
to **~285 KB** in the APK. No AndroidX/Compose, so the APK is ~0.3–0.4 MB.

## Build & run

Prerequisites: the FPC Android cross-compiler at `~/fpc` (see
`docs/TOOLCHAIN.md`), the Android SDK (Android Studio), and a device with USB
debugging on (`adb devices` shows it).

```sh
# 1. build the native renderer (arm64) → app/src/main/jniLibs/arm64-v8a/
cd android
./build.sh

# 2. build + install the APK (needs the Android SDK / Android Studio)
./gradlew installDebug
adb shell am start -n com.tina4.pascal/.MainActivity
```

## Build on Windows (no Gradle, no Mac, no WSL)

A scaffolded project builds a signed APK entirely on a Windows host:

```powershell
tools\tina4pascal.ps1 setup android      # one-time: fetch NDK r21e + build the FPC cross
cd myproject
tools\tina4pascal.ps1 build android       # → build\android\myproject.apk (arm64-v8a + armeabi-v7a)
```

Default ABIs are the real-device pair; override with tina4.json `"androidAbis"`
or `$env:TINA4_ANDROID_ABIS` — add `x86_64` to run on the standard x86_64
emulator:

```powershell
$env:TINA4_ANDROID_ABIS = 'arm64-v8a armeabi-v7a x86_64'
tools\tina4pascal.ps1 build android
adb install -r build\android\myproject.apk
adb shell am start -n <bundleId>/com.tina4.pascal.MainActivity
```

Verified live on an `android-36` x86_64 emulator: `libtina4.so` loads and the
FPC engine renders the UI through JNI → `android.graphics.Canvas`.

How it works — the CLI resolves every tool by explicit path (never `PATH`):

- **FPC → `libtina4.so`**: stock FPC has no Android cross-compiler, so
  `setup android` builds one from FPC source against **NDK r21e** (the last NDK
  that still ships the GNU `as`/`ld` FPC 3.2.2 drives) and installs a
  version-locked pack — `ppcrossa64.exe`/`ppcrossarm.exe` + `aarch64/arm-android`
  RTL + `jni`/`fpkg` units — into the FPC tree. See
  `toolchain\build-android-cross.ps1`; that same script is the "rebuild on every
  FPC release" CI step (the `.ppu` are FPC-version-stamped, never committed).
- **Packaging**: the project's UI is rendered to `showcase.html` (`--dump-html`),
  then `javac → d8 → aapt2 → zipalign → apksigner` from the Windows Android SDK
  build-tools produce a debug-signed APK with the project's own `applicationId`.

`tools\tina4pascal.ps1 doctor` reports the whole chain (FPC crosses, SDK,
build-tools, platform, NDK, JDK).

Or open the `android/` folder in Android Studio and press **Run**. Gradle
bundles the prebuilt `libtina4.so`; it does not rebuild it — re-run
`./build.sh` after changing any Pascal source.

To render a different page, replace `app/src/main/assets/index.html`.

## Status

MVP: static documents render (text, type, lists, SVG vector, cards, buttons,
colours) with Android's own text shaping + anti-aliasing. Touches are
hit-tested natively (`nativeTouch` → `HitTest` → nearest `onclick`/link).
Not yet wired: scrolling, text input/IME, image decode (`<img>`), and routing
`onclick` to app handlers — these are the next steps, mirroring the desktop
viewer. arm64 only for now; add ABIs in `app/build.gradle` + `build.sh`.
