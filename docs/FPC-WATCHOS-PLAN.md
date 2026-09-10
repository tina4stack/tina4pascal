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
pointers** (ILP32). Route A (FPC-LLVM) is the way — LLVM already supports
`arm64_32-apple-watchos`, so LLVM does the codegen and we don't hand-write an
ILP32 arm64 assembler.

### Progress (verified this session)

- **M1 ✅ FPC-LLVM builds and runs on this host.** A clean `make compiler LLVM=1`
  built a working LLVM-backed `ppca64` (442,068 lines vs 413,588 native — the
  delta is the LLVM backend); it answers `-il` with the LLVM/Xcode version list
  and carries the `-Cl…` LLVM codegen flags. The "does the less-travelled LLVM
  path even build here" gate is passed. Apple's side was never in doubt: `clang
  -target arm64_32-apple-watchos` emits a real `arm64_32 · platform WATCHOS`
  object here.
- **M2 finding — the real crux, and it's deeper than "a `tsysteminfo` with
  `ptrsize=4`."** Pointer size on aarch64 is **compile-time**, not a per-target
  runtime value: `compiler/fpcdefs.inc` unconditionally `{$define cpu64bitaddr}`
  for `aarch64` (line ~343), and `compiler/aarch64/cpubase.pas` hardcodes
  `OS_ADDR = OS_64`. So a single aarch64 compiler binary is **always** LP64 — no
  target record can make it emit 32-bit pointers. **The good news:** FPC already
  separates `cpu64bitalu` (64-bit registers) from `cpu64bitaddr` (64-bit
  pointers), which is exactly arm64_32's shape (64-bit ALU, 32-bit ptrs) — so the
  model *can* express it. **The catch:** no shipping FPC CPU uses
  `cpu64bitalu` **without** `cpu64bitaddr`, so arm64_32 would be the first — a
  **novel CPU-ABI variant**, not a config tweak.

### What M2 actually requires

A new AArch64 **ILP32 build variant** (call it `aarch64_ilp32`):
1. An `fpcdefs.inc` path that defines `cpu64bitalu` but **not** `cpu64bitaddr`,
   and an `OS_ADDR = OS_32` for it → a **separately-built** compiler binary
   (LP64 and ILP32 can't be the same `ppca64`).
2. A `tsysteminfo` for `arm64_32-apple-watchos`: `ptrsize=4`, the ILP32
   `llvmdatalayout` (`…-p:32:32-i64:64-…-n32:64-S128`), watchOS platform (4).
3. An audit of every `{$ifdef cpu64bitaddr}` path and the aarch64 backend for
   ILP32 correctness (much of the codegen is delegated to LLVM, which lowers the
   risk, but the frontend size/alignment model and the RTL must be clean).
4. RTL + engine built through FPC-LLVM for the target; link with Apple's `ld`
   (`-platform_version watchos …`), which already accepts arm64_32.

Risk: **high but bounded** — LLVM owns the hard instruction selection; the work
is a first-of-its-kind ILP32-on-AArch64 frontend variant plus RTL foot-guns
(anything assuming `PtrInt=Int64`). Realistically a multi-week focused effort and
a genuine upstream-FPC-scale contribution — not a config change. Route B (teach
the internal aarch64 assembler ILP32) is strictly worse; don't.

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
