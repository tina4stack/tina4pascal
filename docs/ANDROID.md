# Building Tina4Pascal for Android

The renderer runs on Android as a native `libtina4.so` that draws through
`android.graphics.Canvas` over JNI (see `src/Tina4ShellAndroid.pas` and
`android/`). This doc is the build recipe **and the hard-won learnings** — the
things that cost hours the first time.

## One-command flow

```sh
tools/tina4pascal doctor      # check toolchain
tools/tina4pascal setup android   # download SDK + NDK (Homebrew) if missing
tools/tina4pascal deploy      # build both ABIs, package, install, launch
tools/tina4pascal debug       # deploy + screenshot + on-device log (dev loop)
```

`build.sh` compiles the `.so` for every ABI in `ABIS`; `build-apk.sh` packages
a signed debug APK **without Gradle** (aapt2 + d8 + zipalign + apksigner), so
no Android Studio is required. Gradle is still supported (open `android/` in
Android Studio).

## Toolchain pieces

| Piece | Where | Installed by |
|---|---|---|
| FPC arm64 cross | `~/fpc` (ppca64 + aarch64-android RTL) | `toolchain/build-crosses.sh` |
| FPC **arm (32-bit)** cross | `~/fpc` (ppcrossarm + arm-android RTL) | see below |
| Android NDK r29 | `/opt/homebrew/share/android-ndk` | `brew install --cask android-ndk` |
| SDK build-tools + platform | `/opt/homebrew/share/android-commandlinetools` | `brew install --cask android-commandlinetools` + `sdkmanager` |
| adb | on PATH | platform-tools |

## ABIs — build BOTH

Modern phones are `arm64-v8a`; **many budget/older phones are 32-bit
`armeabi-v7a` only** (e.g. the V2_PRO this was first tested on). Installing an
arm64-only APK there fails with `INSTALL_FAILED_NO_MATCHING_ABIS`. `build.sh`
builds both by default.

## Learnings (the expensive ones)

1. **32-bit ARM: assemble with GNU `as`, not clang.** FPC emits pre-UAL ARM
   syntax (`strneb`, `streqb`); the NDK clang integrated assembler rejects it
   (`invalid instruction`). Point the `arm-linux-androideabi-as` wrapper at
   `arm-linux-gnueabihf-as` (`brew install arm-linux-gnueabihf-binutils`) with
   `-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp`. (arm64 is the opposite —
   clang's assembler is fine for aarch64.)

2. **Link with GNU `ld`.** FPC 3.2.2 generates a linker script `ld.lld`
   rejects ("unable to insert .data after .data1"). Route
   `arm-linux-androideabi-ld` → `arm-linux-gnueabihf-ld`. Android arm objects
   are plain ARM ELF, so a Linux GNU ld links them fine.

3. **`fpc.cfg` hardcoded aarch64 for all Android.** The stock `#ifdef android`
   block sets `-XPaarch64-linux-android-`; targeting arm then used the wrong
   assembler prefix/bindir. Split it per CPU (`#ifdef cpuaarch64` /
   `#ifdef cpuarm`) — each with its own `-XP`, `-FD` (wrapper bindir) and
   `-Fl` (NDK sysroot libs). arm libs live at
   `…/sysroot/usr/lib/arm-linux-androideabi/21`.

4. **`ppcrossarm` → `ppcarm`.** `make crossinstall CPU_TARGET=arm` builds
   `ppcrossarm` but leaves it in `lib/fpc/3.2.2/`; the `fpc` driver invokes
   `ppcarm`. Copy it to `~/fpc/bin/ppcrossarm` and symlink `ppcarm → ppcrossarm`.

5. **Float ABI.** Build the RTL with `-CpARMV7A -CfVFPV3` so it matches the
   `armeabi-v7a` VFP ABI.

6. **JNI drawing.** `TAndroidCanvas` calls `Canvas`/`Paint`/`Path` via the FPC
   `jni` unit. Cache class + method IDs once; use the `…MethodA` variants with
   a `jvalue[]` (not varargs). Colours are `$AARRGGBB` = Android's packed int.
   `Paint.ascent()` is negative → baseline = topY − ascent.

7. **Replaced elements as flex/block items.** `<svg>`/`<qrcode>`/`<img>` used
   directly as a flex item were laid out as containers (their children as HTML)
   and vanished. Fixed with `MakeReplacedBox` in the layout engine — build them
   as atoms wherever they appear, not only when gathered inline.

8. **`screencap` on a slept screen is pure black.** Wake first
   (`input keyevent KEYCODE_WAKEUP`) before capturing; `tina4pascal screenshot`
   does this.

9. **On-device logging.** `Tina4ShellAndroid.AndroidLog` → liblog (`external
   'log'`); read with `tina4pascal logcat` (tag `tina4`). Enable a debuggable
   build for CheckJNI if a JNI call misbehaves.

## Building the 32-bit arm cross (one-time)

```sh
brew install arm-linux-gnueabihf-binutils
# wrappers in ~/fpc/cross/bin/arm-android/ (as → GNU as, ld → GNU ld) — see
# learnings 1–2; then:
ln -sfn <NDK>/…/sysroot/usr/lib/arm-linux-androideabi/21 ~/fpc/cross/lib/arm-android-ndk21
cd ~/fpc-dev/fpc-3.2.2
make crossall crossinstall OS_TARGET=android CPU_TARGET=arm PP=~/fpc/.../ppca64 \
  INSTALL_PREFIX=~/fpc OVERRIDEVERSIONCHECK=1 OPT="-XR$(xcrun --show-sdk-path)" \
  CROSSBINDIR=~/fpc/cross/bin/arm-android BINUTILSPREFIX=arm-linux-androideabi- \
  CROSSOPT="-CpARMV7A -CfVFPV3"
cp ~/fpc/lib/fpc/3.2.2/ppcrossarm ~/fpc/bin/ && ln -sf ppcrossarm ~/fpc/bin/ppcarm
# add the per-CPU android block to ~/fpc/etc/fpc.cfg (learning 3)
```
