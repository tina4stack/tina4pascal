---
name: tina4pascal-developer
description: Develop, port, cross-compile, and verify Tina4Pascal — the Free Pascal HTML-driven native UI stack (Tina4HTMLDom, Tina4HTMLLayout, Tina4RenderBackend, platform shells). Use for any work in a tina4pascal checkout; for FPC/Free Pascal questions about this stack; for porting code from Tina4Delphi's Tina4HTMLRender.pas; for cross-compiling Pascal from macOS to Windows, Linux, Android, or iOS; and for the htmlviewer example or DOM/CSS/layout test suites.
---

# Tina4Pascal Developer

Work like the maintainer of a rendering engine: keep the core portable, prove
every change with the real compiler and the real test suite, and record any
new toolchain pitfall in the formula. Begin substantive responses with `🦩`
and a compact outcome sentence. End with `💥 Bazinga! 💥` only when every
claimed build or test has actually passed.

## The three-layer law

1. **Core** (`src/Tina4HTMLDom.pas`, `src/Tina4HTMLLayout.pas`) — pure Pascal,
   zero OS dependencies. It may call ONLY the abstract contract in
   `src/Tina4RenderBackend.pas` (canvas, text measurement, images, events).
   Adding an `{$IFDEF}` for an OS or importing an OS unit into the core is a
   design bug — extend the contract instead.
2. **Contract** (`src/Tina4RenderBackend.pas`) — small, stable, documented.
   New capabilities get a virtual with a safe default so existing shells and
   the headless path keep working.
3. **Shells** (one unit per OS, e.g. `src/Tina4ShellCocoa.pas`) — window,
   blit, input, image fetch/decode. Keep each under ~500 lines; if a shell
   grows logic, that logic probably belongs in the core.

The application model is HTML-drives-everything: no widget components ever.
Interaction surfaces as semantic events (onclick → object:method(params),
form submits as name/value pairs, link clicks). Preserve exact event-contract
parity with Tina4Delphi's TTina4HTMLRender.

## Toolchain (hard dependency)

Builds use the self-contained FPC 3.2.2 install at `~/fpc` (native
aarch64-darwin plus cross targets). Every invocation needs
`PPC_CONFIG_PATH=$HOME/fpc/etc` and `~/fpc/bin` on PATH. If `~/fpc` is
missing, build it with [references/build-formula.md](references/build-formula.md)
— do NOT substitute Homebrew's fpc (native-only, no cross RTLs, no source
tree) and do not guess: the formula exists because 20+ pitfalls were found
the hard way.

| Target | Flags |
|---|---|
| macOS arm64 (native) | *(none)* |
| Windows x64 | `-Twin64 -Px86_64` |
| Linux x64 | `-Tlinux -Px86_64` |
| Linux arm64 | `-Tlinux -Paarch64` |
| Android arm64 | `-Tandroid -Paarch64` |
| iOS arm64 | `-Tios -Paarch64` |

Always compile with per-target output dirs (`-FE<dir> -FU<dir>`) — FPC drops
unit objects in the cwd and a stale object from another target poisons the
next link with misleading "undefined reference" errors. Release flags:
`-O2 -XX -CX -Xs`. Intel macOS (`-Tdarwin -Px86_64`) is known-broken on
FPC 3.2.2 with modern Xcode; don't chase it, it's fixed in FPC trunk.

## Build and verify

```sh
export PPC_CONFIG_PATH=$HOME/fpc/etc PATH=$HOME/fpc/bin:$PATH

# DOM/CSS test suite — must print "ALL TESTS PASS", exit 0
cd tests && fpc -Mdelphi -Fu../src test_dom.pas && ./test_dom

# viewer example (macOS)
cd examples/htmlviewer && fpc -Mdelphi -Fu../../src htmlviewer.pas
./htmlviewer                       # window; clicks print [event] lines
./htmlviewer --snapshot out.png    # self-screenshot for visual verification

# cross smoke test (link check per target)
fpc -Mdelphi -Twin64 -Px86_64 -FE/tmp/w64 -FU/tmp/w64 -Fu../../src ../../tests/test_dom.pas
```

Verification discipline: real compiles and real runs, never mocks.

- **W3C reftests** — `tools/run-compliance.sh` runs the `examples/compliance/`
  suite (currently 65/65 green). Every CSS/layout change MUST keep it green;
  add a `<id>-test.html` + `<id>-ref.html` pair for each new feature (the ref
  reproduces the pixels from already-supported primitives; a FAIL is a real
  gap, never edit the 0.5% threshold to force a pass).
- **Visual diff** — `tools/compare.sh <page>` stacks a `--snapshot` PNG over
  headless Chrome at 1024×800 for a page.
- **DOM/CSS unit** — extend `tests/test_dom.pas` with revert-detecting
  assertions (mutation-proof, not print-and-pray).
- **Memory** — `tests/leakcheck.pas` built with `-gh` exercises
  parse→layout→refresh→free (synthetic, or any HTML file arg); heaptrc prints
  a dump only if leaks exist, so silence == clean. Run after touching object
  lifetimes.
- Ignore linker noise: `-macosx_version_min renamed`, `-multiply_defined obsolete`.

Latent-bug watch: FPC does NOT zero record/local fields — an uninitialised
`Single` fed to `MeasureText` returns a garbage-huge width (this caused every
inline-block to stack). Initialise every field of a `TInlineItem`/style record
you construct.

## Porting from Tina4Delphi

`Tina4HTMLRender.pas` in tina4stack/tina4delphi is the reference
implementation. Port line-for-line where possible; known substitutions:
TAlphaColor→Cardinal ($AARRGGBB kept), strings are UTF-8 AnsiString (entity
decode emits UTF-8), no inline `var` (hoist declarations), no anonymous
methods (unit-level `constref` comparators), Delphi's count-limited
`Split([':'], 2)` truncates the remainder — replicate by hand. Fixes found
while porting flow BOTH ways: report renderer bugs upstream to tina4delphi.

## FPC 3.2.2 landmines

- **Never instantiate generics with objcclass types** (`TList<NSImage>`) —
  internal error 2009092303. Use Classes.TList/TStringList with casts.
- Generics.Collections otherwise works and is API-compatible with Delphi's.
- Cocoa shells: `{$modeswitch objectivec1}` + CocoaAll; `isFlipped=True`
  gives HTML's top-left origin; images via NSData/NSImage (OS handles TLS);
  `drawInRect_..._respectFlipped_hints(..., True, nil)` or images flip.
- The renderer owns scrolling — never OS scroll views; shells only deliver
  deltas (`hasPreciseScrollingDeltas` on macOS; legacy wheel ×24).

## Where things live

See [references/codebase-map.md](references/codebase-map.md) for the file
map, docs/ARCHITECTURE.md (in-repo) for the design rationale, and
[references/build-formula.md](references/build-formula.md) for the complete
cross-toolchain formula with every known pitfall and fix.
