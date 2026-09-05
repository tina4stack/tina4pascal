# HTML element index — full coverage tracker

Every standard HTML element (per the
[MDN HTML elements reference](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements)),
with its status in the Tina4Pascal renderer. Companion to
`CSS-PROPERTY-INDEX.md`. Goal: every rendered element ✅.

**Re-audited 2026-09-05 against the source.** Corrections from the old tracker
are flagged inline.

Status: ✅ Rendered correctly · 🟡 Partial · ⬜ Intentionally not rendered
(metadata/scripting) · ❌ Missing (should render, doesn't).

## Main root & metadata

| Element | Status | Note |
|---|---|---|
| html, body | ✅ | layout roots |
| head, meta, base | ⬜ | not rendered |
| title | ⬜ | ignored (inner text can leak as a stray node — minor) |
| link[rel=stylesheet] | 🟡 | href captured into `LinkHrefs`; **inline `<style>` is applied, external `<link href>` is not fetched yet** (remote-CSS roadmap) |
| style | ✅ | parsed into the stylesheet |

## Content sectioning

| Element | Status | Note |
|---|---|---|
| header, footer, main, section, article, aside, nav | ✅ | block |
| h1–h6 | ✅ | UA sizes + weight + margins |
| hgroup | 🟡 | **computes inline** (tracker said block); heading children still stack |
| address | 🟡 | block; italic UA not applied |

## Text content

| Element | Status | Note |
|---|---|---|
| div, p | ✅ | block + margins |
| ul, ol | ✅ | block + indent + markers |
| menu | ❌ | **not rendered as a list** (tracker wrongly said ✅) — no block/indent/markers |
| li | ✅ | list-item + marker |
| dl, dt, dd | ✅ | bold term, indented def |
| blockquote | ✅ | indent + left border |
| pre | ✅ | monospace, whitespace preserved |
| hr | 🟡 | thin bordered block; no dedicated rule line |
| figure, figcaption | 🟡 | block; default 40px margins not applied |

## Inline text semantics

| Element | Status | Note |
|---|---|---|
| a, span | ✅ | inline; a emits link events |
| b, strong, i, em, u, ins | ✅ | bold/italic/underline |
| s, del | ✅ | line-through |
| strike | ❌ | **no strikethrough** (tracker wrongly said ✅) — legacy tag unwired |
| small, mark, code, kbd, samp, var | ✅ | mark = yellow bg; code/kbd/samp mono |
| sub, sup | ✅ | baseline shift + smaller |
| abbr, cite, dfn, q, br | ✅ | q = auto quotes |
| wbr | ❌ | no break opportunity |
| bdi, bdo | ❌ | no bidi/direction override |
| time, data | 🟡 | inline text only |
| ruby, rt, rp | ❌ | render inline (not annotated) |

## Image & multimedia

| Element | Status | Note |
|---|---|---|
| img | ✅ | remote fetch + decode + cache + aspect (all platforms) |
| svg | ✅ | pure-Pascal vector painter (`Tina4SVG`) — no gradients/clip/`<use>` yet |
| qrcode | ✅ | **Tina4 custom** — pure-Pascal QR encoder |
| camera | ✅ | **Tina4 custom** — "Take Photo" → shell capture |
| picture, source, srcset | ✅ | responsive selection (media/type/density/width/sizes) |
| video, audio, canvas, iframe, object, map | ❌ | media/embed belong in shells; canvas needs a draw hook |
| track, area, embed | ⬜ | void children / not applicable |

## Tina4 custom tags

| Element | Status | Note |
|---|---|---|
| include[src] | ✅ | fetches HTML + splices in place, caches, nested, per-tag auth headers |
| secure | ✅ | redacted under capture-protection (see `TinaSetCaptureProtected`) |

## Table content

| Element | Status | Note |
|---|---|---|
| table | ✅ | auto/explicit column sizing, `border` attr |
| thead, tbody, tfoot | 🟡 | rows flattened in **source order** — **tfoot not moved to bottom**, no sticky/repeat |
| tr, td | ✅ | |
| th | 🟡 | renders as a cell; **no default bold/center** |
| colspan (attr) | ✅ | both layout passes |
| rowspan (attr) | ❌ | multi-row cells collapse, following rows misalign |
| caption | ❌ | dropped by row collection, never painted |
| col, colgroup | ❌ | ignored (widths from content only) |

## Forms

| Element | Status | Note |
|---|---|---|
| form | ✅ | block; submit collects name=value |
| input[text/email/password/search/number] | 🟡 | all collapse to one text input; **no password masking**, no number stepper |
| input[checkbox] | ✅ | draw + toggle, `:checked` stylable |
| input[radio] | ✅ | draw + group exclusivity by name |
| input[submit/button] | ✅ | drawn button + press feedback |
| input[file] | ✅ | "Choose File" → shell picker; shows filename |
| **input[date]** | ✅ | **native calendar picker** — formatted display (`format` attr), month nav, today, ISO value (see examples/datepicker) |
| input[color/range/tel/url/…] | 🟡 | editable plain text; no swatch/slider |
| textarea | 🟡 | multi-line + line-aware caret; **append/backspace-at-end only** (no mid-text edit) |
| select, option | ✅ | drawn dropdown overlay with ✓ |
| optgroup | ❌ | grouped options **not shown** (only direct `<option>` read) |
| button | ✅ | drawn; submit |
| label | ✅ | `for=`/wrapping/sibling all wired to focus+toggle |
| fieldset, legend | 🟡 | border + bold legend (not notched) |
| datalist | ❌ | **leaks its options as visible text** (should be invisible) |
| output | 🟡 | text renders; no form binding |
| progress, meter | ❌ | render nothing (no bar) |

## Interactive & scripting

| Element | Status | Note |
|---|---|---|
| details, summary | 🟡 | honors `open` statically + draws ▸/▾; **tapping does not toggle** |
| dialog | 🟡 | renders as a block **always visible** — no `open`/modal/backdrop |
| script | ✅ | content skipped (not rendered) |
| noscript | 🟡 | children render (non-spec, harmless) |
| template | ❌ | **content renders** (should be inert) |
| slot | 🟡 | passthrough (no shadow DOM) |

## Misc

| Element/Attr | Status | Note |
|---|---|---|
| onclick (any element) | ✅ | semantic `obj:method(args)` + `:active` feedback |
| id / class / style | ✅ | selectors + inline styles (inline wins) |
| hidden attribute | ✅ | ⇒ display:none |

## Priority element gaps (by impact)

1. **details/summary tap-toggle** — ubiquitous accordion, currently dead.
2. **external `<link href>` CSS fetch** — enables theme/look distribution from a URL (reuses the HTTP+cache path).
3. **table rowspan**, `<caption>`, `<col>/<colgroup>`; th default bold/center; tfoot-to-bottom.
4. **Forms**: password masking, `optgroup`, `input[color/range]` widgets, `progress`/`meter` bars, caret navigation / mid-text editing.
5. **template/datalist leak** (should be inert); **dialog** open/modal.
6. **menu** as list; **strike** strikethrough; **hgroup** block — small correctness fixes.
7. Inline: `wbr`, `bdi/bdo`, `ruby`; media `video`/`audio`/`canvas` (shell-owned).
