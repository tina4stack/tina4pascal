# Adding a watchOS target to FPC

**Goal.** Let FPC emit watchOS binaries so the Tina4 engine runs **natively on the
Apple Watch** — the way it already runs on Wear OS (Android/arm64) — instead of
the phone/Mac render-and-stream mirror (`docs/WATCH.md`). watchOS is Darwin
(Mach-O, ARM, libSystem), the same family FPC already supports for macOS and iOS,
so this is additive compiler work, not a rewrite.

## The two problems, and why one is much smaller

A watchOS target needs (1) the right **CPU ABI** and (2) a **watchOS OS
sub-target** (platform tagging, SDK, RTL). The ABI is where the difficulty lives —
but it splits by *where the code runs*:

| Runs on | CPU / ABI | FPC support today |
|---|---|---|
| **watchOS Simulator** (Apple Silicon Mac) | **arm64 (LP64, 64-bit ptrs)** — sim binaries are built for the *host* arch | **Already supported** (FPC `aarch64`) |
| **Physical Apple Watch** (S4+) | **arm64_32 (ILP32 — arm64 ISA, 32-bit ptrs)** | **Not supported** |

That table is the whole plan. The **simulator does not need arm64_32** — it's plain
arm64 with a *watchos-simulator* platform tag. So FPC's existing aarch64 code
generator already produces valid simulator object code; only the OS sub-target is
missing. The physical watch is the hard part (`arm64_32`), and it can be deferred.

## Phase 1 — watchOS **Simulator** target (tractable)

Reuses FPC's arm64 backend unchanged. Deliverable: `-Twatchossim -Paarch64`
compiles the engine, links a watch-sim static lib, and it runs in the watchOS
Simulator (proving the engine on the watch, no arm64_32).

Concrete FPC source touch-points (mirror the existing iOS/`iphonesim` entries):
1. **`compiler/systems.pas`** — add the target enum, e.g.
   `system_aarch64_watchossim` (and later `system_arm64_32_watchos`), to the
   `tsystem` enumeration and the OS/CPU tables.
2. **`compiler/systems/i_bsd.pas`** — add the `tsysteminfo` record for it, cloned
   from the `aarch64-iphonesim`/`aarch64-ios` entry: `system=…`, `name='watchOS
   Simulator'`, Mach-O output, endianness, alignment, `abi`, and the correct
   `llvmdatalayout`. Pointer size stays 8 (arm64).
3. **Mach-O platform tag** — the object/link path must stamp
   **`PLATFORM_WATCHOSSIMULATOR` (9)** instead of iOS (`LC_BUILD_VERSION`). FPC
   links through Apple's `ld`, so this is mostly passing
   `-platform_version watchos-simulator <min> <sdk>` in the linker invocation
   (`compiler/systems/t_bsd.pas`, where the iOS `-ios_simulator_version_min` /
   `-platform_version` flags are built) plus, if the internal Mach-O writer is
   used, the platform constant in `compiler/ogmacho.pas`.
4. **SDK/sysroot** — point `-XR`/`-Fl` at
   `Xcode.app/…/WatchSimulator.sdk`; add it to the cross-build config
   (`fpc.cfg`/`fpcmake`).
5. **RTL** — build `rtl/darwin` for the new target: add it to the RTL
   `Makefile.fpc`/`fpmake`; the `System` unit + syscalls are the same libSystem
   as iOS, so this largely follows the iOS RTL with the OS name swapped.

Risk: **low–moderate**. No new codegen; it's plumbing that closely parallels the
existing `iphonesim` target. Most bugs will be linker-flag / SDK-path issues.

## Phase 2 — physical watch (**arm64_32**)

The real device needs `arm64_32`: the AArch64 instruction set with **32-bit
pointers** (ILP32). FPC's aarch64 backend assumes 64-bit pointers throughout
(`ptrsize=8`, PtrInt=Int64, ABI, stack layout), so this is genuine backend work.
Two routes:

- **Route A — FPC-LLVM backend (recommended).** FPC's LLVM code generator emits
  LLVM IR and lets LLVM do instruction selection. **LLVM already supports
  `arm64_32-apple-watchos`** (that's how clang/Swift build watch apps). So the
  work is: add the `arm64_32` sub-target to FPC-LLVM — the target triple, the
  ILP32 `llvmdatalayout` (`p:32:32` on the arm64 base), and a `tsysteminfo` with
  `ptrsize=4` — and let LLVM handle the ABI/codegen. This sidesteps writing an
  ILP32 arm64 assembler by hand. It does require the FPC-LLVM toolchain and an
  RTL built for ILP32 (careful with any code assuming `PtrInt=Int64`).
- **Route B — internal aarch64 codegen.** Teach FPC's own aarch64 backend
  (`compiler/aarch64/cgcpu.pas`, `cpupara.pas`, `aasmcpu.pas`, node CGs) a
  32-bit-pointer mode. Deepest option: pointer size, calling convention, address
  arithmetic, RTL type sizes. High effort, high risk. Only if avoiding LLVM.

Risk: **high** either way; Route A is the lower-risk path because the hard
codegen is LLVM's. Expect ILP32 RTL foot-guns (anything sizing a pointer as 8).

## Effort & sequencing

1. **Phase 1 (sim)** first — small, proves the OS sub-target + RTL end to end and
   immediately lets the engine run in the watchOS Simulator (retiring the mirror
   there). Weeks, not months, for someone fluent in FPC's Darwin target code.
2. **Phase 2 (device, arm64_32 via LLVM)** — larger; unlocks real hardware.
3. Upstream both to FPC (it benefits every Pascal watch project), or carry as a
   patched FPC in this repo's toolchain (`toolchain/`) if upstream is slow.

## Where this plugs into Tina4Pascal

Once Phase 1 lands, `tools/tina4pascal` gains a real `build watchsim` (compile the
engine `-Twatchossim -Paarch64 -Cn` → `libtina4watch.a`, linked by the watchOS
Xcode target) — the exact twin of the iOS pipeline (`ios/build.sh`,
`proj_ios_stage`). The `watch/` app then embeds the engine and calls
`tina4_frame`/`tina4_touch` directly instead of streaming frames — the Apple
Watch becomes a native engine surface like every other platform, and
`docs/WATCH.md`'s Apple-mirror section is superseded by native rendering.

## Honest bottom line

- **Simulator: genuinely doable** (no arm64_32) — the highest-value first step.
- **Device: real compiler work** (arm64_32), best via FPC-LLVM.
- Neither is a fundamental barrier; both are "nobody has done it in shipping FPC
  yet," and the phasing means the simulator win doesn't wait on the hard ABI part.
