# ADR-0010: Includes, runtime view navigation, and an embedded page store

- **Status:** Accepted
- **Date:** 2026-10-02

## Context

An app that is many screens needs a way to compose and switch pages. The web does
this with navigation (a new document) or an `<iframe>`/router (a foreign tree).
Tina4Pascal renders ONE native DOM with no WebView (ADR-0002), so neither fits:
there is no page-to-page navigation to hook, and an `<iframe>` would mean a second
engine. (ADR-0016 later added `<iframe>` for *external* web content, hosted by the
OS web view. That does not change this decision: app screens still compose with
`<include>` and views.) Authors still want three things:

1. **Compose** — pull a reusable partial (header, card, screen) into a page.
2. **Navigate** — swap the visible screen at runtime without reloading the whole
   document or losing the native frame around it.
3. **Store** — decide where a screen's HTML lives, ideally without baking it into
   Pascal string constants or inventing per-screen build variables.

A `<include src>` tag already existed for (1) but only resolved `http(s)` URLs —
the promised "local or from a URL" never worked off-device, and there was no
runtime swap or storage story at all.

## Decision

Everything is a **splice into the one live DOM**, then `GLayoutDirty := True`. No
reload, no second tree. One resolution path backs all of it, checked in order:
**embedded page store → local file (asset/bundle base) → http(s) async**.

### Compose — `<include src>` resolves locally too
`ProcessInclude` ([src/Tina4Interact.pas](../../src/Tina4Interact.pas)) now reads a
non-`http` src straight off disk via a new backend virtual
`TTina4Canvas.ReadLocalFile` — default reads the process dir; the Android/iOS
shells override it to resolve against the same asset base a relative `<img src>`
uses (ADR-0001: new capability = new virtual + safe default + per-OS override).

### Navigate — runtime view swapping
Three public procedures, each clearing the container (freeing the outgoing screen
and dropping focus/open-dropdown that pointed into it) then splicing:

- `TinaSetViewHtml(container, html)` — an in-memory fragment.
- `TinaLoadView(container, src)` — a local file or a URL.
- `TinaShowView(container, templateId)` — clone an inert `<template>`.

Exposed to pure HTML as the built-in actions **`view.load`** and **`view.show`**,
so a multi-screen app needs no app code at all.

### Store — where a screen's HTML lives
Three options, the **same `src` for all of them**:

- **Inline `<template>`** — parsed-but-inert; `view.show` clones it. One file, no
  bundling.
- **`assets/`** — copied verbatim into the APK/IPA (and present on desktop); the
  `ReadLocalFile` resolver finds it by relative path.
- **Embedded page store** — pages under `pages/` are base64-compiled by
  `tina4pascal pages` into a generated `Tina4EmbeddedPages` unit whose
  initialization calls `RegisterEmbeddedPageB64`. `Tina4Pages`
  ([src/Tina4Pages.pas](../../src/Tina4Pages.pas)) holds the registry, and the
  resolver checks it **before disk**, so a single executable needs no filesystem.
  Auto-wired into the host `uses` on mobile; opt-in with `uses Tina4EmbeddedPages;`
  on desktop.

## Consequences

- One mechanism (splice + relayout) covers compose, navigate and store on every
  target; the engine never gains a router or a second render tree.
- The embedded store keeps screens as real `.html` files in `pages/`, not Pascal
  string constants — base64 sidesteps all literal-escaping, and the generated unit
  is a build artifact (`.tina4/`, git-ignored).
- `TinaShowView` deep-clones the source `<template>` (it is reusable), so inline
  screens cost a clone per navigation; file/embedded screens cost a parse.
- Covered by [tests/test_includes.pas](../../tests/test_includes.pas) (local
  splice, view swaps, template reuse, built-in actions, embedded store) and
  demonstrated by `examples/multiscreen`.

## Alternatives considered

- **`<iframe>`/second engine** — rejected (ADR-0002): a foreign tree, double the
  memory, no shared styling.
- **FPC `{$R}` resources for embedding** — rejected: platform-specific resource
  compilation vs. a pure-Pascal generated unit that links identically everywhere.
- **Baking includes at `--dump-html`** — the Twig layer already resolves
  `{% include %}`/`{% extends %}` for the entry page; DOM-level `<include>`/views
  are deliberately a *runtime* splice so screens can load on demand on-device.
