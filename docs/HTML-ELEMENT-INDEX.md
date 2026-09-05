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
| hgroup | ✅ | block; heading children stack |
| address | ✅ | block + italic UA |

## Text content

| Element | Status | Note |
|---|---|---|
| div, p | ✅ | block + margins |
| ul, ol | ✅ | block + indent + markers |
| menu | ✅ | renders as a list (block + indent + disc markers), like ul |
| li | ✅ | list-item + marker |
| dl, dt, dd | ✅ | bold term, indented def |
| blockquote | ✅ | indent + left border |
| pre | ✅ | monospace, whitespace preserved |
| hr | 🟡 | thin bordered block; no dedicated rule line |
| figure, figcaption | ✅ | block; figure has UA 1em/40px margins |

## Inline text semantics

| Element | Status | Note |
|---|---|---|
| a, span | ✅ | inline; a emits link events |
| b, strong, i, em, u, ins | ✅ | bold/italic/underline |
| s, del | ✅ | line-through |
| strike | ✅ | line-through (legacy alias of s/del) |
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
| thead, tbody, tfoot | ✅ | tfoot rows moved to the bottom regardless of source order; no sticky/repeat |
| tr, td | ✅ | |
| th | ✅ | UA bold + center |
| colspan (attr) | ✅ | both layout passes |
| rowspan (attr) | ✅ | cell reserves its columns downward; following rows shift correctly |
| caption | ✅ | full-table-width block above (default) or below rows; caption-side honored |
| col, colgroup | ✅ | per-column width via width attr or style; span honored |

## Forms

| Element | Status | Note |
|---|---|---|
| form | ✅ | block; submit collects name=value |
| input[text/email/password/search/number] | 🟡 | password now masks (•); text otherwise; no number stepper |
| input[checkbox] | ✅ | draw + toggle, `:checked` stylable |
| input[radio] | ✅ | draw + group exclusivity by name |
| input[submit/button] | ✅ | drawn button + press feedback |
| input[file] | ✅ | "Choose File" → shell picker; shows filename |
| **input[date]** | ✅ | **native calendar picker** — formatted display (`format` attr), month nav, today, ISO value (see examples/datepicker) |
| input[color/range/tel/url/…] | ✅/🟡 | color swatch + range slider drawn; tel/url as text |
| textarea | 🟡 | multi-line + line-aware caret; **append/backspace-at-end only** (no mid-text edit) |
| select, option | ✅ | drawn dropdown overlay with ✓ |
| optgroup | ✅ | label row + indented options in the dropdown; nested options selectable and resolved when closed |
| button | ✅ | drawn; submit |
| label | ✅ | `for=`/wrapping/sibling all wired to focus+toggle |
| fieldset, legend | 🟡 | border + bold legend (not notched) |
| datalist | ✅ | inert (display:none UA); options never painted |
| output | 🟡 | text renders; no form binding |
| progress, meter | ✅ | drawn bars (progress accent, meter green) from value/max |

## Interactive & scripting

| Element | Status | Note |
|---|---|---|
| details, summary | 🟡 | honors `open` statically + draws ▸/▾; **tapping does not toggle** |
| dialog | 🟡 | hidden unless `open`; open = bordered box in flow; no modal backdrop/centering (needs scripting) |
| script | ✅ | content skipped (not rendered) |
| noscript | 🟡 | children render (non-spec, harmless) |
| template | ✅ | inert (display:none UA); content never painted |
| slot | 🟡 | passthrough (no shadow DOM) |

## Misc

| Element/Attr | Status | Note |
|---|---|---|
| onclick (any element) | ✅ | semantic `obj:method(args)` + `:active` feedback |
| id / class / style | ✅ | selectors + inline styles (inline wins) |
| hidden attribute | ✅ | ⇒ display:none |

## Priority element gaps (by impact)

**Done since last audit:** tables complete (rowspan, `<caption>`+caption-side,
`<col>`/`<colgroup>`, tfoot-to-bottom, th bold/center); template/datalist inert.

Outstanding, by impact:

1. **details/summary tap-toggle** — ubiquitous accordion, currently dead (renders
   open/closed statically but does not toggle on tap).
2. **`<optgroup>` in `<select>`** — grouped options not shown (only direct
   `<option>` read); labels + indented options in the dropdown overlay.
3. **`<dialog>`** open/modal/backdrop — currently always-visible block.
4. **external `<link href>` CSS fetch** — theme/look distribution from a URL
   (reuses the HTTP+cache path).
5. **Forms**: number stepper; `output` form-binding; textarea mid-text editing;
   fieldset notched legend.
6. Small correctness: **menu** as list; **strike** strikethrough; **hgroup**
   block; **figure** default 40px margins; **address** italic UA.
7. Inline: `wbr`, `bdi/bdo`, `ruby/rt/rp`; media `video`/`audio`/`canvas`/`iframe`
   (shell-owned); `time`/`data` are inline-only today.
