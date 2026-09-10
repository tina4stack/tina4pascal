# FPC watchOS target — Phase 1 patch (watchOS **Simulator**, aarch64)

Concrete, source-accurate diffs to add a **watchOS-Simulator** target to FPC,
written against the current `freepascal.org/fpc/source` tree (`compiler/`). The
simulator on Apple Silicon is plain **arm64 (LP64)** — so this reuses FPC's
existing aarch64 backend and adds only a Darwin OS sub-target. No `arm64_32`.
(Confirmed live: `xcodebuild` reports the *physical* watch as `arch:arm64_32`;
the *simulator* is arm64 — that split is why Phase 1 is small and Phase 2 isn't.)

> Status: this is an implementation patch, **not** a submitted merge request. It
> needs a compiler build + on-simulator test pass before it's MR-ready. FPC uses
> **GitLab merge requests** (gitlab.com/freepascal.org/fpc/source), not GitHub PRs,
> and first-time contributors sign the FPC contributor agreement.

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

## Build & test the patched compiler
```sh
# in the fpc source tree, build a cross compiler + RTL for the new target
make clean
make compiler_cycle
make rtl OS_TARGET=watchossim CPU_TARGET=aarch64 \
     CROSSOPT="-XR$(xcrun --sdk watchsimulator --show-sdk-path)"
# then: fpc -Twatchossim -Paarch64 -Cn a test unit; link with Xcode's watch-sim target
```
A green compile + a unit that runs in the watchOS Simulator is the bar for the MR.

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
