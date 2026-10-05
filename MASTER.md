# Tina4Pascal — MASTER

The one-page map of the project: what it is, how it's kept honest, and where the
decisions and plans live. Start here.

Tina4Pascal is a Free Pascal engine that renders HTML + CSS natively — its own DOM,
layout and canvas, no WebView — across macOS, Windows, Linux, Android and iOS, from
one codebase. It is the FPC sibling of Tina4Delphi's `TTina4HTMLRender`.

## Architecture in one breath

Three layers, strictly separated (ADR-0001): **core** (pure Pascal renderer) →
**contract** (`Tina4RenderBackend`, abstract virtuals) → **shells** (one per OS).
Apps are HTML, not widgets; interaction is semantic events (ADR-0002). Read
`docs/ARCHITECTURE.md` for the rationale and `skills/tina4pascal-developer/` for the
working guide.

## Verify before you claim

A claimed pass must be a real pass. The harnesses (run with `PPC_CONFIG_PATH=$HOME/fpc/etc`,
`~/fpc/bin` on PATH):

| Check | Command | Bar |
|---|---|---|
| Portable suite | `tools/tina4pascal test` | all suites pass |
| Layout compliance (ours-vs-ours reftests) | `sh tools/run-compliance.sh` | 0 fail |
| Raster reftests | `sh tools/run-raster-tests.sh` | 0 fail |
| **ours-vs-Chrome** (the truth check) | `TINA4_CHROME=… ./tools/compare-all.sh` | ≤2% diff, 0 unexpected |

`docs/CSS-PROPERTY-INDEX.md` and `docs/HTML-ELEMENT-INDEX.md` are the source of
truth for coverage — keep them honest.

## Build & release

- Targets + flags: see `skills/tina4pascal-developer/` (macOS native; `-Twin64`,
  `-Tlinux`, `-Tandroid -Paarch64`, `-Tios -Paarch64`). Toolchain is vendored FPC
  3.2.2 at `~/fpc` via `toolchain/build-crosses.sh` (ADR-0003). iOS is device-only
  (ADR-0005). Android is gradle-free (ADR-0006).
- Release: `tools/release-windows.sh` / `release-macos.sh` — Authenticode + GPG +
  SHA-256 (ADR-0007).

## Planning discipline

Every substantive maintenance task gets a **plan doc**; every lasting design choice
gets an **ADR**. Conventions and templates: [`plan/README.md`](plan/README.md).

### Decisions (ADRs) — `plan/adr/`
- [ADR-0001](plan/adr/0001-three-layer-architecture.md) — three-layer architecture
- [ADR-0002](plan/adr/0002-html-drives-everything.md) — HTML drives everything
- [ADR-0003](plan/adr/0003-vendored-fpc-toolchain.md) — vendored FPC 3.2.2 toolchain
- [ADR-0004](plan/adr/0004-macos-ios-os-tls.md) — macOS/iOS use OS TLS, not OpenSSL
- [ADR-0005](plan/adr/0005-ios-device-only.md) — iOS is device-only
- [ADR-0006](plan/adr/0006-gradle-free-android.md) — gradle-free Android packaging
- [ADR-0007](plan/adr/0007-signed-releases.md) — signed, verifiable releases
- [ADR-0008](plan/adr/0008-text-editing-and-highlighting.md) — `<codearea>`, highlighter registry, text-edit model
- [ADR-0009](plan/adr/0009-inline-script-extract-compile.md) — inline `<script type="text/pascal">` extracted + compiled
- [ADR-0010](plan/adr/0010-code-folding.md) — `<codearea>` code folding by indentation
- [ADR-0011](plan/adr/0011-transform-percent-resolution.md) — `translate()` `%` resolves against the element's own box
- [ADR-0012](plan/adr/0012-onmousemove-event.md) — `onmousemove` DOM event dispatched to app code
- [ADR-0013](plan/adr/0013-builtins-dom-node-api.md) — runtime DOM node primitives in Tina4Builtins

### Task plans — `plan/`
- [code-editing-highlighting](plan/code-editing-highlighting.md) — `<codearea>` + Tina4Highlight
- [code-folding](plan/code-folding.md) — `<codearea>` indentation folding (Tina4CodeFold)
- [android-emulator-kitchen-sink](plan/android-emulator-kitchen-sink.md)
- [ios-device-tooling-maintenance](plan/ios-device-tooling-maintenance.md)
- [mcp-surface-audit](plan/mcp-surface-audit.md)
- [mobile-scroll-render-optimizations](plan/mobile-scroll-render-optimizations.md)
- [readme-mobile-emulators](plan/readme-mobile-emulators.md)

## Skills

- `skills/tina4pascal-developer/` — building apps & features, porting, cross-compiling.
- `skills/tina4pascal-maintainer/` — maintaining the library: plan/ADR discipline,
  verification, PR review, releases.
