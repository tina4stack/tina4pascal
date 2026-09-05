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
| hr | ✅ | UA thin grey rule line (1px block) + 8px margins |
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
| wbr | ✅ | zero-width break opportunity (line wraps there when needed) |
| bdi, bdo | 🟡 | text renders inline; bidi/direction override needs RTL support (not near-term — engine is LTR) |
| time, data | ✅ | inline text (no visual difference required; value/datetime are metadata) |
| ruby, rt, rp | 🟡 | children render inline; no stacked ruby annotation (CJK-specific, deferred) |

## Image & multimedia

| Element | Status | Note |
|---|---|---|
| img | ✅ | remote fetch + decode + cache + aspect (all platforms) |
| svg | ✅ | pure-Pascal vector painter (`Tina4SVG`) — no gradients/clip/`<use>` yet |
| qrcode | ✅ | **Tina4 custom** — pure-Pascal QR encoder |
| camera | ✅ | **Tina4 custom** — "Take Photo" → shell capture |
| picture, source, srcset | ✅ | responsive selection (media/type/density/width/sizes) |
| video | ✅ iOS · ✅ Android · 🟡 macOS | core lays out a sized poster box + exposes it via `tina4_embed_*` (all shells). **iOS** ✅ verified on device — `AVPlayerViewController` (play/pause/scrub/skip/fullscreen/AirPlay). **Android** ✅ verified on device — `VideoView` + `MediaController` (play/pause/scrub) overlaid in a host `FrameLayout`, muted looping autoplay. **macOS** 🟡 wired + compiles — Cocoa `AVPlayerView` (AVKit); verify pending a GUI run |
| audio | ❌ | outstanding — shell-owned native audio player over a core placeholder box |
| canvas | ❌ | outstanding — needs a Tina4 native draw hook (no JS engine) |
| iframe | ⬜ | **intentionally not supported** — Tina4 composes pages with `<include src>` (native HTML splice into the same render tree), not a foreign web view |
| object, map | ⬜ | legacy embed / image maps — not planned |
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
| input[text/email/password/search/number] | 🟡 | all accept text + focus/caret; password masks (•). Type-specific affordances (numeric/email soft-keyboard, number steppers) pending a keyboard-type shell contract — steppers are a desktop convention; touch uses a typed keyboard |
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
| output | 🟡 | renders its text; live form-binding needs a script/eval model (deferred) |
| progress, meter | ✅ | drawn bars (progress accent, meter green) from value/max |

## Interactive & scripting

| Element | Status | Note |
|---|---|---|
| details, summary | ✅ | draws ▸/▾ + honors `open`; tapping the summary toggles open/closed (mobile `TinaTouch` + desktop `MouseUp`) |
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

## Outstanding (verified against source 2026-09-05)

Everything not listed here is ✅ or ⬜ in the tables above. Each row is corrected
in the same commit that changes its behaviour — this list is the truth, not a
wishlist.

**Core-renderable, still open (in priority order):**
1. **external `<link href>` CSS fetch** — theme/look distribution from a URL
   (reuses the `<img>` HTTP+cache path). `link` row is 🟡 for this reason.
2. **Forms polish** — `input[number]` stepper buttons; `<output>` form-binding;
   `<textarea>` mid-text editing (append/backspace-at-end today);
   `<fieldset>`/`<legend>` notched border.
3. **`<dialog>` modal** — backdrop + centering (`showModal`); needs the scripting
   model. Non-modal open/closed already works.

**Media — outstanding HTML, shell-owned (NOT done):**
4. **`video`** — in progress (iOS AVPlayer overlay over the core placeholder box).
5. **`audio`** — native audio player over a core-laid box.
6. **`canvas`** — a Tina4 native draw hook (no JS engine).
   (`iframe` is intentionally not supported — use `<include src>`; `object`/`map`
   are not planned.)

**Deferred (need a larger subsystem, intentionally later):**
6. **`bdi`/`bdo`** — bidi/direction override needs RTL support (engine is LTR).
7. **`ruby`/`rt`/`rp`** — stacked CJK annotation positioning.

**Done since the previous audit:** whole tables set (rowspan, caption+side,
col/colgroup, tfoot, th); template/datalist inert; `<optgroup>`; `<dialog>`
open/closed; details/summary tap-toggle (was already wired — doc was stale);
menu list, strike, hgroup, figure margins, address italic, hr rule line, wbr,
time/data.
