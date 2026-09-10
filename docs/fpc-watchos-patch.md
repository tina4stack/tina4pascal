# FPC watchOS target — Phase 1 patch (watchOS **Simulator**, aarch64)

Concrete, source-accurate diffs to add a **watchOS-Simulator** target to FPC,
written against the current `freepascal.org/fpc/source` tree (`compiler/`). The
simulator on Apple Silicon is plain **arm64 (LP64)** — so this reuses FPC's
existing aarch64 backend and adds only a Darwin OS sub-target. No `arm64_32`.
(Confirmed live: `xcodebuild` reports the *physical* watch as `arch:arm64_32`;
the *simulator* is arm64 — that split is why Phase 1 is small and Phase 2 isn't.)

> **Status: BUILT + TESTED — a Pascal program runs on the watchOS Simulator.**
> Applied to FPC trunk (3.3.1), the patched `ppca64` compiles `-Twatchossim
> -Paarch64`, the full Darwin RTL (system…sysutils…classes) builds for the target,
> and a linked `Mach-O arm64 · platform WATCHOSSIMULATOR · minos 10.0` executable
> **ran on the Apple Watch Series 11 simulator** and printed its output (exit 0).
> The exact applied diff is [`fpc-watchossim.diff`](fpc-watchossim.diff) (11 files,
> ~104 lines) and the reproducible editor is [`fpc-watchossim-apply.py`](fpc-watchossim-apply.py).
> Still **not** a submitted merge request: FPC uses **GitLab merge requests**
> (gitlab.com/freepascal.org/fpc/source), not GitHub PRs, and first-time
> contributors sign the FPC contributor agreement.

### What the theoretical patch got wrong (fixed in the applied diff)
- **No `.build_version` in `aggas.pas`** — FPC never emits that directive; the
  Mach-O platform tag comes from the **clang triple** in `compiler/triplet.pas`.
  watchossim needs its own `arm64-apple-watchosVER-simulator` triple (not the
  shared `-ios-simulator`), or objects tag platform 7 (iOS-sim) and Xcode's ld
  rejects them. This replaced touch-point #4 entirely.
- **Modern `ld` dropped `-watchos_simulator_version_min`** (Xcode 26). The linker
  min-version must be the unified `-platform_version watchos-simulator <min> <sdk>`
  form in `t_darwin.pas` `GetLinkVersion`.
- **`-Twatchossim` needs no `options.pas` parser change** — `find_system_by_string`
  matches `upper(shortname)`, so shortname `'watchOSSim'` resolves automatically.
- **The RTL can't be built via `make`** — the generated `rtl/Makefile` (and stock
  `fpcmake`) enumerate known targets and reject `aarch64-watchossim`. Build the
  units directly from `rtl/darwin` with the new compiler (recipe below).

## The target: `system_aarch64_watchossim`

Clone the existing `aarch64-iphonesim` target — it's the exact analogue (arm64,
Darwin, Mach-O, simulator). Touch-points, each mirroring an `iphonesim` line:

### 1. `compiler/systems.inc` — add the enum value
After `system_aarch64_iphonesim` in the `tsystem` enumeration, add:
```pascal
system_aarch64_watchossim,   { new — next free number }
```
(and bump `last_system`/the count constant just below the enum).

### 2. `compiler/systems/i_darwin.pas` — the `tsysteminfo` record
Copy the whole `system_aarch64_iphonesim_info : tsysteminfo = ( … )` record to
`system_aarch64_watchossim_info` and change only:
```pascal
system    : system_aarch64_watchossim;
name      : 'Darwin/watchOS Simulator for AArch64';
shortname : 'watchOSSim';
```
Everything else (flags, `cpu_aarch64`, `endian_little`, the Darwin ext/prefix
block, `as_clang_asdarwin`, `ld_darwin`, `res_macho`, alignment) is identical.
Then register it at unit init like the others: `RegisterTarget(system_aarch64_watchossim_info);`

### 3. `compiler/systems.pas` — the target **sets**
Add the new system to each Darwin/iOS-family set so shared code treats it right:
```pascal
systems_watchossim = [system_aarch64_watchossim];              { new }
systems_darwin      = … + [system_aarch64_watchossim];
systems_objc_nfabi  = … + [system_aarch64_watchossim];         { line ~368 }
systems_caller_copy_addr_value_para = … + [system_aarch64_watchossim]; { ~456 }
```
(Wherever `system_aarch64_iphonesim` appears in a set that means "arm64 Darwin
simulator", add the watch sim beside it.)

### 4. `compiler/aggas.pas` — the Mach-O build-version directive
In the per-target block that emits the min-OS / build-version directive
(~lines 556–644, where `system_*_iphonesim` are cased), add
`system_aarch64_watchossim` and emit the **watchOS-simulator** platform
(`.build_version watchos-simulator …`, LC_BUILD_VERSION platform **9**).

### 5. `compiler/systems/t_darwin.pas` — the linker min-version flag
Beside the `'-iphoneos_version_min '` logic (~line 376), add the watch-sim flag.
Modern `ld` prefers the unified form:
```pascal
result := '-platform_version watchos-simulator '+WatchOSVersionMin.str+' '+SDKVersion.str;
```
plus a `WatchOSVersionMin` option (clone `iPhoneOSVersionMin`) and point the SDK
sysroot at `WatchSimulator.sdk`.

### 6. `compiler/objcgutl.pas` — Obj-C NFABI guard
Add `system_aarch64_watchossim` to the target set at ~line 1832 (the
`not(target_info.system in [ … iphonesim … ])` check) so Obj-C metadata emits.

### 7. `compiler/options.pas` — accept `-Twatchossim`
Add the target-name mapping so `fpc -Twatchossim -Paarch64` resolves (mirror the
`iphonesim` string → `system_*_iphonesim` handling).

### 8. RTL — `rtl/darwin`
Add the target to `rtl/darwin/Makefile.fpc` / `fpmake.pp` so the System unit +
SysUtils build for it. The syscalls are the same libSystem as iOS, so this
largely follows the iOS RTL with the OS name swapped and the watchOS-sim SDK.

## Build & test the patched compiler — the recipe that actually worked
```sh
# 0. full FPC trunk source tree; apply the diff
git apply docs/fpc-watchossim.diff        # or: python3 docs/fpc-watchossim-apply.py

# 1. rebuild the native compiler — it bakes in the new target (all RegisterTarget'd
#    targets are cross-reachable from the aarch64-darwin host, same CPU)
cd compiler && make compiler OS_TARGET=darwin CPU_TARGET=aarch64 FPC=~/fpc/bin/ppca64
PPC=$PWD/ppca64                            # the patched compiler

# 2. build the RTL for watchossim by driving the compiler over rtl/darwin directly
#    (make/fpcmake reject the unknown target). Capture the darwin recipe, then swap
#    compiler -> $PPC, add -Twatchossim -Paarch64, outdir -> aarch64-watchossim,
#    -XR -> the watch-sim SDK. See fpc-watchossim-apply.py's sibling transform.
SDK=$(xcrun --sdk watchsimulator --show-sdk-path)
#    -> rtl/units/aarch64-watchossim/*.ppu (system, sysutils, classes, objc, …)

# 3. compile + link a program and run it in the simulator
$PPC -Twatchossim -Paarch64 -Fu<rtl>/units/aarch64-watchossim -XR"$SDK" whello.pp
vtool -show whello | grep -E 'platform|minos'   # WATCHOSSIMULATOR / 10.0
WID=$(xcrun simctl list devices available | grep -m1 'Apple Watch' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$WID"; xcrun simctl spawn "$WID" ./whello   # -> prints, exit 0
```
**Verified:** `Tina4 on watchOS-sim: 2+2=4` on Apple Watch Series 11 (46mm) sim.
A green compile + a program that runs in the watchOS Simulator is the bar — cleared.

## Phase 2 (physical watch, `arm64_32`) — separate
The device needs the ILP32 ABI. Best route is the **FPC-LLVM** backend: LLVM
already supports `arm64_32-apple-watchos`, so add the triple + ILP32 datalayout +
a `tsysteminfo` with `ptrsize=4`, and let LLVM do codegen — rather than teaching
FPC's internal aarch64 assembler 32-bit pointers. See `docs/FPC-WATCHOS-PLAN.md`.

## How this lands in Tina4Pascal
Once Phase 1 builds, `tools/tina4pascal` gains `build watchsim` (compile the
engine `-Twatchossim -Paarch64 -Cn` → `libtina4watch.a`, linked by the watchOS
Xcode target) — the twin of `ios/build.sh`. The `watch/` app then embeds the
engine and calls `tina4_frame`/`tina4_touch` directly, and the streaming mirror
(`examples/watch/watch_server.py`) is retired for the simulator — the Apple
Watch becomes a native engine surface like every other platform.
