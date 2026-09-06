# HTML element index — full coverage tracker

Every standard HTML element (per the
[MDN HTML elements reference](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements)),
with its status in the Tina4Pascal renderer. Companion to
`CSS-PROPERTY-INDEX.md`. Goal: every rendered element ✅.

**Re-audited 2026-09-06 against the source** (every ✅ spot-checked in code; added
the `<search>` landmark found missing). Corrections are flagged inline.

Status: ✅ Rendered correctly · 🟡 Partial · ⬜ Intentionally not rendered
(metadata/scripting) · ❌ Missing (should render, doesn't).

## Main root & metadata

| Element | Status | Note |
|---|---|---|
| html, body | ✅ | layout roots |
| head, meta, base | ⬜ | not rendered |
| title | ⬜ | ignored (inner text can leak as a stray node — minor) |
| link[rel=stylesheet] | ✅ | inline `<style>` and external `<link href>` both applied. Relative hrefs load from beside the HTML; remote URLs are fetched once through the shell (`FetchToFile`) into a local `csscache/` and reused. Cascade order preserved (links before inline `<style>`) |
| style | ✅ | parsed into the stylesheet |

## Content sectioning

| Element | Status | Note |
|---|---|---|
| header, footer, main, section, article, aside, nav | ✅ | block |
| search | ✅ | block landmark (wraps a search form) — added to the block-tag set |
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
| video | ✅ iOS · ✅ Android · 🟡 macOS | core lays out a poster box + exposes rect/src/**flags**/poster via `tina4_embed_*`. Attributes honored per shell: `controls`, `autoplay`, `loop`, `muted` (bitmask), and `poster` (painted as the box background by the core). **iOS** ✅ `AVPlayerViewController`. **Android** ✅ `VideoView`+`MediaController` in a host `FrameLayout`. **macOS** 🟡 Cocoa `AVPlayerView` (AVKit; loop TODO) — compiles, verify pending a GUI run |
| audio | ✅ | `<audio controls>` = a core-laid 300×54 placeholder box with a shell-owned native player over it (bare `<audio>` is `display:none`). Shares the `<video>` embed pipeline: `tina4_embed_*` now reports **kind** (0 video · 1 audio); AVPlayer/AVPlayerView (macOS+iOS) and Android VideoView all play audio. Attributes: controls/autoplay/loop/muted via the same flag bitmask |
| canvas | ✅ | **pure-Pascal Canvas 2D** (`Tina4Canvas2D`) — an app registers a painter for `<canvas id>`; draws with the familiar methods (rects, paths, arc/bezier/quadratic, fill/stroke, text, transforms, globalAlpha, drawImage). Core-rendered → every shell + snapshot-testable. No JS, no Skia |
| iframe | ⬜ | **intentionally not supported** — Tina4 composes pages with `<include src>` (native HTML splice into the same render tree), not a foreign web view |
| object, map | ⬜ | legacy embed / image maps — not planned |
| track, area, embed | ⬜ | void children / not applicable |

## Tina4 custom tags

| Element | Status | Note |
|---|---|---|
| include[src] | ✅ | fetches HTML + splices in place, caches, nested, per-tag auth headers |
| secure | ✅ | redacted under capture-protection (see `TinaSetCaptureProtected`) |
| lottie | ✅ | **Tina4 custom** — pure-Pascal Lottie/Bodymovin player (`Tina4Lottie`) rendering inline JSON via Canvas 2D; shape layers, bezier paths, fills/strokes, keyframed transforms + parenting, cubic-bezier easing; animates off the ticker. No Skia/JS. Verified on iPhone |

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
| input[text/email/password/search/number] | ✅ | all accept text + focus/caret; password masks (•). `number` paints a right-edge ▴/▾ spinner; clicking it steps `value` by `step` (default 1), clamped to min/max, firing `change`. (numeric/email soft-keyboard still pending a keyboard-type shell contract) |
| input[checkbox] | ✅ | draw + toggle, `:checked` stylable |
| input[radio] | ✅ | draw + group exclusivity by name |
| input[submit/button] | ✅ | drawn button + press feedback |
| input[file] | ✅ | "Choose File" → shell picker; shows filename |
| **input[date]** | ✅ | **native calendar picker** — formatted display (`format` attr), month nav, today, ISO value (see examples/datepicker) |
| input[color/range/tel/url/…] | ✅/🟡 | color swatch + range slider drawn; tel/url as text |
| textarea | ✅ | multi-line editing: click positions the caret (line by Y, column by X); type/backspace/delete at the caret; Enter splits the line; ←/→ and ↑/↓ navigate (↑/↓ keep the column across lines) |
| select, option | ✅ | drawn dropdown overlay with ✓ |
| optgroup | ✅ | label row + indented options in the dropdown; nested options selectable and resolved when closed |
| button | ✅ | drawn; submit |
| label | ✅ | `for=`/wrapping/sibling all wired to focus+toggle |
| fieldset, legend | ✅ | bordered group; the legend straddles the top border and notches it (masks the segment behind its background) |
| datalist | ✅ | inert (display:none UA); options never painted |
| output | ✅ | `<output formula="a * 2 + b">` recomputes from named field values via a built-in arithmetic evaluator (+ − × ÷, parens); recalculated on `oninput="output.recalc()"` and seeded at load. No JS engine |
| progress, meter | ✅ | drawn bars (progress accent, meter green) from value/max |

## Interactive & scripting

| Element | Status | Note |
|---|---|---|
| details, summary | ✅ | draws ▸/▾ + honors `open`; tapping the summary toggles open/closed (mobile `TinaTouch` + desktop `MouseUp`) |
| dialog | ✅ | `dialog.show(id)`/`dialog.close(id)` open/close it in flow; `dialog.showModal(id)` centres it over a dimmed backdrop (top layer). Driven by the built-in event actions from a plain `onclick` — no JS engine |
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
| `<!-- comments -->` | ✅ | stripped by the parser (`SkipComment`) — content and any tag-like text inside are dropped, never a stray node |
| `<!DOCTYPE>` | ✅ | skipped (`SkipDoctype`) |

## Outstanding (verified against source 2026-09-05)

Everything not listed here is ✅ or ⬜ in the tables above. Each row is corrected
in the same commit that changes its behaviour — this list is the truth, not a
wishlist.

**Core-renderable, still open:** none — the element inventory is complete. A
minimal event hook (`Tina4Builtins`: `dialog.show/showModal/close`,
`output.recalc` + a tiny arithmetic evaluator, dispatched from plain `onclick`/
`oninput` via `Tina4Events`) unblocked the last two (`<output>`, `<dialog>`
modal) without a JS engine. Anything richer (arbitrary scripting) stays out of
scope by design — native apps consume APIs built elsewhere.

**Done recently:** `<output>` formula binding + `<dialog>` show/close/modal (event
hook); `<textarea>` mid-text editing; `input[number]` steppers; `<fieldset>`
notch; external `<link href>` CSS fetch (`FetchToFile` → `csscache/`).

**Media — all done:** `video` (iOS `AVPlayerViewController` + Android `VideoView`;
macOS Cocoa `AVPlayerView` 🟡 loop TODO), `audio` (shares the video embed
pipeline, `tina4_embed_kind` 0/1), `canvas` (pure-Pascal `Tina4Canvas2D`),
`lottie` (pure-Pascal `Tina4Lottie`). `iframe`/`object`/`map` intentionally not
rendered (use `<include src>`).

**Deferred (need a larger subsystem, intentionally later):**
- **`bdi`/`bdo`** — bidi/direction override needs RTL support (engine is LTR).
- **`ruby`/`rt`/`rp`** — stacked CJK annotation positioning.

**Done since the previous audit:** whole tables set (rowspan, caption+side,
col/colgroup, tfoot, th); template/datalist inert; `<optgroup>`; `<dialog>`
open/closed; details/summary tap-toggle (was already wired — doc was stale);
menu list, strike, hgroup, figure margins, address italic, hr rule line, wbr,
time/data.
