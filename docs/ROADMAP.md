# Tina4Pascal — master roadmap

The sequencing plan. **HTML/CSS faithfulness comes first** — the renderer is the
product; the component library, themes, and the IDE all sit on top of it and are
only as good as the engine underneath. We do not start the IDE until the
renderer is faithful enough that what you author is what you get.

Companion trackers (the authoritative, code-audited gap lists):
[CSS-PROPERTY-INDEX.md](CSS-PROPERTY-INDEX.md) · [HTML-ELEMENT-INDEX.md](HTML-ELEMENT-INDEX.md).

---

## Phase 0 — shipped

The interaction + data foundation is in and cross-platform (macOS/iOS/Android;
Windows/Linux shells pending):

- Parse → cascade → layout → paint → hit-test pipeline; flexbox, tables (colspan),
  overflow scroll, transforms, opacity, `--vars`/`var()`.
- **CSS pseudo-classes** `:hover`/`:active`/`:focus`/`:checked` + `appearance:none`.
- **@media** breakpoints + `prefers-color-scheme: dark` (incl. dark `:root` var swaps).
- **Native controls**: text/checkbox/radio/select-overlay/file/camera, and a
  first-class **`<input type=date>`** calendar (formatting, month + decade nav).
- **font-family reaches the canvas** on all three shells (real fonts, not one system font).
- **`<include src>`** HTML snippets (auth + sandbox + cache), **async cached remote `<img>`**,
  native-TLS **HTTP** service, **Frond** template engine, **capture protection**
  (`class="sensitive"`), services (cache/store/docs).
- Quick wins: outline paint, min/max-height, `<details>`/`<summary>` toggle.

---

## Phase 1 — FINISH HTML + CSS (the prerequisite)

Close the audited gaps until an author can trust the box. Ordered by impact ÷ effort.

### 1a. Layout correctness
- **Flexbox faithfulness**: `flex-shrink` pass, `align-items:stretch`,
  `align-content`/`align-self`/`order`, per-axis `row-gap`/`column-gap`.
- **position: fixed/sticky** (viewport-pinned) + **z-index** paint ordering.
- **CSS Grid** (`display:grid` + `grid-template-*`, `gap`) — the single biggest
  real-world unlock after flex.
- **aspect-ratio**; **float/clear** (legacy/email).

### 1b. Paint fidelity
- **background-image: url()** paint (parse infra already there; reuse the async img cache).
- **Real gradients** — linear (angle + multi-stop) and radial via a backend gradient op
  (today's linear is a flat midpoint).
- **box-shadow** soft blur + inset + radius-aware (today: hard edge, outset only).
- **Per-side borders** + **border-style** (dashed/dotted/double) (today: Top side, solid).

### 1c. Typography
- ✅ **@font-face** downloadable fonts — parse + fetch (async/disk-cached) +
  `RegisterFont` on all three shells, CSS family aliased to the real face.
- **font-weight** numeric (light/medium/semibold/black).
- **text-overflow: ellipsis**, **overflow-wrap/word-break**, **white-space: pre-wrap**.
- **text-shadow** paint, **text-indent**, **text-decoration** overline + color/style.

### 1d. Functions & at-rules
- **calc()** `*` `/` + `%`/viewport terms; **clamp()/min()/max()/env()**.
- **external `<link href>` CSS fetch** (theme-from-URL; reuse HTTP+cache) →
  enables Phase 2 theme distribution.

### 1e. HTML elements
- Table **rowspan**, `<caption>`, `<col>/<colgroup>`, `th` defaults, tfoot-to-bottom.
- Forms: password masking, `optgroup`, `input[color/range]`, `progress`/`meter`,
  **caret navigation / mid-text editing**.
- `<dialog>` open/modal; `<template>`/`<datalist>` inert; `menu`/`strike`/`hgroup` fixes.

**Every item ships a reftest under `examples/compliance/` and flips its row in the
trackers. The gate to Phase 2: the compliance suite covers each shipped feature
and stays green (currently 73/73).**

---

## Phase 2 — Components + themes library

Once the box is faithful, make it *sing* with ready-made building blocks.

- **Component library** — curated, reusable **Frond partials** in the Tina4 design
  language *and* a Bootstrap-flavoured set: cards, navbars, forms, modals, toasts,
  tabs, the date picker, segmented controls, tables, empty states. Dropped in via
  `<include src>` (local or from a URL).
- **Themes** — token files (the `@media`-dark palette we already wired) that restyle
  a whole app from one import; distributable over remote CSS.
- A **gallery** demo app that showcases every component in light + dark.

This library is also the **IDE's palette** later — so it's built first.

---

## Phase 3 — The IDE (only after Phases 1–2)

The ambition: an HTML/Frond editor with Pascal hooks that uses **FPC** to build
cross-platform apps, with debugging. The pieces already exist (the `tina4pascal`
CLI drives FPC; the engine renders live) — the IDE assembles them.

1. **Hot-reload dev loop** — `tina4pascal dev` watches the HTML/Frond and live-reloads
   the running app (templates are runtime; no recompile). "Any editor + live preview."
2. **Inspector / debug overlay** — toggle a panel in the running app: DOM tree,
   computed styles, the JSON context, and a log of every dispatched action.
   App-model debugging without a native debugger.
3. **The editor app** — a Tina4-*built* editor (dogfooding) with the Phase-2
   component palette, a live preview pane, and a "Build for iOS/Android/macOS"
   button that shells the CLI.
4. **Native Pascal debugging** — lldb integration for breakpoints in action
   handlers (FPC already emits debug info with `-gl`).

---

## Cross-cutting

- **iOS Simulator + Android emulator build targets** — FPC 3.2.2 only targets iOS
  *device* (`AARCH64IOS`), so the engine can't run in the iOS Simulator today (device
  deploy only); a simulator build (FPC trunk's simulator target, or an SDK/ABI shim) is
  required so the dev loop doesn't need a physical iPhone. Android device builds
  (`-Tandroid -Paarch64`) already run on an **arm64 Android emulator** image — wire that
  into the tooling as a first-class test target too.
- **iOS/Android paint parity** — native gradients (CGGradient / Android shaders) and
  numeric font-weight on those shells; they use the flat-average / binary-bold
  fallbacks today.
- **Windows + Linux shells** (tina4pascal has macOS/iOS/Android today; the core is
  portable and ready). Windows especially matters for parity with tina4delphi.
- **Upstream parity** — port wins here (capture protection, pseudo-classes, cached
  images, date picker) into `tina4delphi`; fixes flow both ways.
- **Binary size** stays tracked per change (OS-TLS ships zero crypto; the engine
  stays lean).

## SDK layer (post CSS/HTML inventory)

Tina4Pascal is an **SDK for rapid native development**, not just a renderer. The
SDK stops at the backend: apps *consume* JSON/REST APIs built with other tools, or
persist to a local store — it never *is* a server. Device/app capabilities are
added to the render-backend contract with a safe default and implemented per shell
(never in the OS-free core), and driven from HTML the Tina4 way (semantic events /
attributes, not widgets):

- **Multiscreen + navigation** — compose an app from a Frond base template + screen
  templates, with built-in `navigate` / `load-template` events and a screen stack.
- **Notifications** — native local (and later push) notifications: contract virtual +
  macOS/iOS `UNUserNotification`, Android `NotificationManager`.
- **Local store** — on-device persistence so simple apps work fully offline (no backend).
- **Remote API data layer** — fetch JSON over the existing HTTP+cache path and bind it
  into a template.

New compiler targets **bolt on** by design: a target is a new shell unit + one row
in the build table — the three-layer law keeps the core and contract OS-free.
