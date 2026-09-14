# FPC iOS Simulator target — building the `aarch64-iphonesim` RTL

The Tina4 engine now runs on the **iOS Simulator** as a native arm64 binary. This
is the recipe that got it there, and the toolchain facts behind it.

> **Status: BUILT + RUNS.** A Pascal `writeln` runs in the iOS Simulator
> (`Tina4 on iOS-sim: 2+2=4`), and the full engine renders HTML on the Simulator
> through the pure-Pascal rasterizer (`ios/sim`, `ios/build-sim.sh`). Verified on
> an iPhone 16 Pro simulator, iPhoneSimulator 26.5 SDK.

## Why FPC 3.2.2 can't do this and the patched compiler can

FPC 3.2.2 ships **no simulator target** — its aarch64 compiler advertises only
iOS, Linux, Android, Darwin. So the device build (`ios/build.sh`, `-Tios`) can't
be pointed at the Simulator; its objects tag Mach-O platform **IOS**, and Xcode's
linker rejects those in a Simulator binary.

The `iphonesim` target is **upstream in FPC trunk** (`system_aarch64_iphonesim`),
and the patched trunk compiler at `~/fpc-watchos/bin/ppca64` (3.3.1, the one the
watchOS-Simulator work built — see `docs/fpc-watchos-patch.md`) already carries
it. iOS device and iOS Simulator are both **arm64 LP64**, so — unlike the watch,
whose device is `arm64_32` — no CPU/ABI change is needed. The compiler already
emits the right clang triple (`arm64-apple-ios<ver>-simulator`, from
`compiler/triplet.pas`), so its objects tag platform **IOSSIMULATOR**.

The only missing piece is the **RTL** for `aarch64-iphonesim`. Building it is the
whole job.

## The one linker gotcha (why the static-lib path is used)

If you ask FPC to *link* an iphonesim executable it will emit
`-ios_simulator_version_min`, which **Xcode 26's `ld` has removed** — modern `ld`
wants the unified `-platform_version ios-simulator <min> <sdk>`. So a direct
`fpc -Tiphonesim … prog.pp` fails at the link step.

Tina4 sidesteps this the same way the watch does: compile with **`-Cn`** (emit
objects, skip FPC's own link), archive them into a static lib, and let **Xcode**
do the final link with its own correct flags. On that path the broken linker flag
never fires. (Fixing it properly is a one-line change to `t_darwin.pas`
`GetLinkVersion` — a legitimate upstream fix, since it bites anyone building for
the iOS Simulator on Xcode 26. FPC takes GitLab merge requests, not GitHub PRs.)

## Recipe — build the RTL

```sh
# 0. a trunk source tree at ~the revision the patched compiler was built from.
#    ppca64 here was built 2026-09-10, so a trunk checkout of that day matches
#    (the .ppu it writes carries ppca64's own PPU version — a same-compiler
#    build is compatible by construction).
cd ~/fpc-dev
git clone --single-branch --branch main --shallow-since=2026-08-20 \
    https://gitlab.com/freepascal.org/fpc/source.git fpc-trunk
cd fpc-trunk && git checkout <commit on/just before the compiler's build date>

PPC=$HOME/fpc-watchos/bin/ppca64
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

# 1. the base RTL. iphonesim is a first-class fpcmake OS target
#    (rtl/Makefile.fpc: dirs_iphonesim=darwin), so the STANDARD make builds it —
#    no manual per-unit compile like watchossim needed.
cd rtl
make clean OS_TARGET=iphonesim CPU_TARGET=aarch64 FPC="$PPC"
make all   OS_TARGET=iphonesim CPU_TARGET=aarch64 FPC="$PPC" OPT="-XR$SDK -Ur"
#   -> rtl/units/aarch64-iphonesim/*.ppu  (system, sysutils, classes, objc, …)

# 2. the package units the engine pulls (fpjson, base64, contnrs, syncobjs,
#    Generics.*, dateutils, strutils, md5/sha1, paszlib). fpmake bootstraps with
#    the WRONG compiler off PATH (Homebrew 3.2.2) and the zsh shell doesn't
#    word-split unquoted vars, so drive ppca64 directly with a flags ARRAY and
#    let it auto-compile dependencies. paszlib's zlib units want -Mobjfpc; the
#    rest take -Mdelphi.  (see the loop in the session notes / this doc's history)

# 3. install alongside the watch RTL so the build scripts find it
cp rtl/units/aarch64-iphonesim/*.ppu rtl/units/aarch64-iphonesim/*.o \
   ~/fpc-watchos/units/aarch64-iphonesim/
```

The result is 133 units — the same set the watchOS-Simulator RTL carries.

## How it lands in Tina4Pascal

- **`ios/build-sim.sh`** compiles `ios/sim/tina4iossim.pas` (the raster engine,
  same C ABI as the watch) `-Tiphonesim -Paarch64 -Cn` and archives it into
  `ios/sim/App/libtina4iossim.a`.
- **`ios/sim/`** is an XcodeGen app that links the lib and blits the engine's
  RGBA — a live HTML clock, drawn on the Simulator with no physical iPhone.

```sh
ios/build-sim.sh                                    # → libtina4iossim.a
cd ios/sim && xcodegen generate
xcodebuild -project Tina4Sim.xcodeproj -scheme Tina4Sim \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/dd CODE_SIGNING_ALLOWED=NO build
DEV=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl install "$DEV" /tmp/dd/Build/Products/Debug-iphonesimulator/Tina4Sim.app
xcrun simctl launch  "$DEV" com.tina4.pascal.sim
```

## What's still raster-only

The Simulator app renders through `Tina4RasterCanvas`, not the native Core
Graphics / Core Text shell (`Tina4ShellIOS`), because the shell needs the
`univint` framework bindings and those aren't built for `aarch64-iphonesim` yet
(they want their package's own build defines — the bare compile hits
`CFBase.pas` "ENDIF without IF(N)DEF"). So the Simulator shows the same
raster fidelity as the watch (7-segment + stroke fonts), not device-identical
CG/CT. Building `univint` for iphonesim — and then compiling `Tina4ShellIOS` for
the sim — is the follow-up (`docs/OUTSTANDING.md`, category F).
