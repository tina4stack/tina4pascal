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
