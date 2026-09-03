# FPC cross-platform toolchain on macOS (Apple Silicon) — working notes

Goal: one FPC 3.2.2 install at `~/fpc` that compiles from a Mac to:
macOS (arm64/x86_64), Windows (win64/win32), Linux (x86_64/aarch64),
Android (aarch64), iOS (aarch64). No Lazarus/IDE.

These notes are the raw material for a future `freepascal-crossplatform` skill.

## Layout

- `~/fpc-dev/` — FPC 3.2.2 source tree + downloads (build area)
- `~/fpc/` — final install prefix (bin, lib, cross/)
- `~/fpc/cross/bin/<cpu>-<os>/` — cross binutils per target
- `~/fpc/cross/lib/<cpu>-<os>/` — target link libraries per target

## Pitfalls found (in order)

1. **Homebrew `fpc` is native-only** — no cross RTLs, no source tree. Use it
   solely as the bootstrap compiler (`/opt/homebrew/bin/ppca64`).
2. **fpcupdeluxe GUI cannot be scripted** — `sources/updeluxe/fpcupdeluxemainform.pas`
   has zero command-line parsing; passing args just opens the window. The console
   `fpcup.lpr` exists in-repo but ships no darwin binary. → build from source manually.
3. **FPC 3.2.2 Makefile rejects 3.2.2 as bootstrap**: "The only supported starting
   compiler version is 3.0.4". Fix: `OVERRIDEVERSIONCHECK=1` (fpcupdeluxe does the same).
4. **Modern Xcode: `ld: library 'c' not found`** when the Makefile compiles with `-n`
   (no fpc.cfg). There is no `/usr/lib/libc.dylib` on modern macOS; the SDK path must
   be passed explicitly: `OPT="-XR$(xcrun --show-sdk-path)"`.
5. Harmless-but-noisy on new ld: `-macosx_version_min has been renamed` and
   `-multiply_defined is obsolete` warnings — ignore.
6. **fpcupdeluxe prebuilt cross tools live under special GitHub release *tags*** on
   LongDirtyAnimAlf/fpcupdeluxe: `darwinarm64crossbins_v1.1` (arm64-darwin-host
   binutils: CrossBinsLinuxx64.zip …), `darwin_arm64_crossbins_all`
   (Linux_AArch64_unknown_V245.zip), `crosslibs_all` (Android_AArch64_API_21.zip,
   Linux_AMD64_Ubuntu_1804.zip, Linux_AArch64_Ubuntu_1804.zip …).
   The arm64-darwin binaries are ad-hoc signed and run natively (curl downloads carry
   no quarantine xattr; `chmod +x` after unzip).
7. Android: no prebuilt android binutils exist for arm64-darwin hosts → use the
   Android NDK (r29 via `brew install --cask android-ndk`); NDK ≥ r23 is llvm-only, so
   FPC needs wrapper scripts mapping `aarch64-linux-android-as` → `clang -c` and
   `-ld` → `ld.lld`. (To be verified.)
8. **NDK cask install path** (not obvious):
   `/opt/homebrew/Caskroom/android-ndk/29/AndroidNDK14206865.app/Contents/NDK`.
   The llvm prebuilt dir is named `darwin-x86_64` but the binaries are actually
   arm64-native (`clang --version` → `Target: arm64-apple-darwin`) — no Rosetta needed.
9. NDK wrapper scripts (in `~/fpc/cross/bin/aarch64-android/`):
   - `aarch64-linux-android-as` → `clang -target aarch64-linux-android21 -c "$@"`
     (clang's integrated assembler accepts FPC's gas-syntax output)
   - `aarch64-linux-android-ld` → `ld.lld "$@"` (lld accepts GNU ld options)
   - `-ar`/`-objdump`/`-strip` → `llvm-ar`/`llvm-objdump`/`llvm-strip`
   Link libraries: prefer the NDK's own sysroot
   (`toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/21/`)
   over the 2016-era fpcupdeluxe Android_AArch64_API_21.zip.

10. **`make crossall` rebuilds the NATIVE compiler first** — so `OPT="-XR$MACSDK"`
    must be passed for EVERY cross target (same 'library c not found' failure as
    pitfall 4 otherwise). Target-specific flags (e.g. the iOS SDK) go in
    `CROSSOPT=`, which only applies to target RTL/package compiles.
11. **linux-x64 cross: `system.pp(490,1) Fatal: Internal error 2015030501`** —
    compiler/assemble.pas:1929: an aarch64-hosted 3.2.2 compiler cannot write
    x87 80-bit extended real constants (host has no `cpuextended`) unless built
    with soft-float support. Fix: add `-dFPC_SOFT_FPUX80` to OPT when building
    a cross-compiler that targets x86 CPUs from an ARM host. (win64 escaped it;
    linux-x64 didn't. aarch64-linux unaffected.)

12. **darwin-x64 cross: `Fatal: Internal error 2014051001`** (genmath.inc) — same
    80-bit-extended class as pitfall 11, in the text-writer path
    (assemble.pas:1137). Same fix.
13. **`-dFPC_SOFT_FPUX80` alone → `Can't find unit sfpux80`** — the soft-x87
    units live in `rtl/inc` (sfpux80.pp/ufloatx80.pp wrapping softfpu.pp) and are
    NOT on the compiler's unit path. Add `-Fu$SRC/rtl/inc -Fi$SRC/rtl/inc` next to
    the define.
14. **Android `as` wrapper must force `-x assembler`** — FPC's android loader
    sources are `prt0.as`/`dllprt0.as`; clang doesn't recognize the `.as`
    extension ("'linker' input unused"), exits 0, and produces NO object file —
    the failure only surfaces later as `install: prt0.o: No such file`. Also
    translate GNU-as `--defsym NAME=VAL` → `-Wa,--defsym,NAME=VAL` (clang errors
    on bare `--defsym`).
15. Cocoa GUI works from plain FPC, no Lazarus: `{$modeswitch objectivec1}` +
    `uses CocoaAll`; NSWindow + NSView subclass (isFlipped=true gives HTML's
    top-left origin), text via NSString drawAtPoint/sizeWithAttributes;
    trackpad scrolling via `hasPreciseScrollingDeltas`/`scrollingDeltaY`
    (legacy `deltaY` is line-based — scale ×24 for wheel mice).

16. **`fpc` driver wants `ppcx64`, not `ppcrossx64`** — 3.2.2's driver doesn't
    probe the ppcross name (`fpc -Px86_64 -PB` shows what it wants). Symlink:
    `ln -s ppcrossx64 ~/fpc/bin/ppcx64` (driver+compilers must be on PATH).
17. **Always build with per-target `-FE`/`-FU` dirs** — FPC drops unit objects
    in the cwd; a stale hello.o from another target silently poisons the next
    link with weird "undefined reference to operatingsystem_parameter_*" /
    missing `_start` errors.
18. **Android linking, two traps**: (a) ld.lld rejects FPC 3.2.2's generated
    linker script ("unable to insert .data after .data1") → point the
    `aarch64-linux-android-ld` wrapper at a GNU ld for aarch64-linux instead
    (Alf's 2.45 works; android objects are plain aarch64 ELF). (b) That BFD ld
    then chokes on NDK r29's lib stubs: ".debug_abbrev is compressed with zstd" —
    make `llvm-strip -g` copies of the sysroot 21/ stubs into a private lib dir
    and -Fl that.

19. **Never instantiate generics with objcclass types** — `TList<NSImage>`
    dies with `generics.defaults.pas Fatal: Internal error 2009092303` on
    FPC 3.2.2/aarch64. Use plain Classes.TList/TStringList (Pointer casts)
    in Objective-Pascal units.
20. Images without external deps on macOS: `NSData.dataWithContentsOfURL`
    (Foundation does TLS + redirects) + `NSImage.initWithData` (decodes
    JPEG/PNG/GIF/WebP). Draw with
    `drawInRect_fromRect_operation_fraction_respectFlipped_hints(..., True, nil)`
    — the respectFlipped=True matters in an isFlipped view.

## Verified size matrix (hello world, 2026-09-03)

| target      | debug   | release (-O2 -XX -CX -Xs) |
|-------------|---------|---------------------------|
| macos-a64   | 464,776 | 169,752 |
| win64       | 175,686 |  45,568 |
| linux-x64   | 412,664 |  26,184 |
| linux-a64   | 519,752 |  66,928 |
| android-a64 | 108,560 |  39,584 (PIE) |
| ios-a64     | 461,200 | 151,992 |

## Source downloads

- FPC 3.2.2 source: sourceforge `freepascal/files/Source/3.2.2/fpc-3.2.2.source.tar.gz` (52 MB)

## Build sequence (native first)

```sh
SDK=$(xcrun --show-sdk-path)
cd ~/fpc-dev/fpc-3.2.2
make all PP=/opt/homebrew/bin/ppca64 OVERRIDEVERSIONCHECK=1 OPT="-XR$SDK"
make install INSTALL_PREFIX=$HOME/fpc PP=... OVERRIDEVERSIONCHECK=1
```

Then per cross target: `make crossall crossinstall OS_TARGET=<os> CPU_TARGET=<cpu> …`

## Status (2026-09-03)

- [x] native aarch64-darwin (brew bootstrap → source build)
- [ ] x86_64-darwin — KNOWN BROKEN: FPC 3.2.2 emits RTTI labels inside
      .cfi regions; new Xcode clang assembler rejects ("non-private labels
      cannot appear between .cfi_startproc/.cfi_endproc"). Fixed in FPC trunk.
- [x] x86_64-win64 (internal assembler/linker — no binutils needed)
- [x] x86_64-linux (soft-x87 fix, pitfalls 11/13)
- [x] aarch64-linux
- [x] aarch64-android (NDK clang-as wrapper + GNU ld + stripped stubs)
- [x] aarch64-ios (Xcode SDK via CROSSOPT)
- [x] Tina4 HTML renderer core ported to FPC (fpc/Tina4HTMLDom.pas, 113
      assertions green) + layout engine + Cocoa viewer: bootstrap_test.html
      renders natively on macOS, near-parity with Chrome for the covered subset.
      Latent Delphi bug found by the port: TComputedStyle.ForTag never sets
      BoxShadow.Active (uninitialised garbage) — report upstream.
- Next: CSS fidelity pass, click/hover interaction, software rasterizer
  (pixel-identical everywhere incl. Android), then tina4pascal repo +
  data layer (websockets, SSE, DB, API) — HTML-template-driven native apps.

21. **Clip save/restore must balance on a flag, not a coincidence** — in the
    Cocoa canvas `SetClip` does `saveGraphicsState`+clip and `ClearClip` does
    `restoreGraphicsState`. A scrollable box at `ScrollTop=0` still opens a clip;
    if ClearClip is gated on "scroll offset changed" it is skipped and the saved
    state leaks, silently clipping everything drawn afterwards (dropdown overlays,
    later siblings). Gate ClearClip on the same boolean that gated SetClip.
