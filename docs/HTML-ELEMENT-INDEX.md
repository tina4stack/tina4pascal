# HTML element index — full coverage tracker

Every standard HTML element (per the
[MDN HTML elements reference](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements)),
with its status in the Tina4Pascal renderer. Companion to
`CSS-PROPERTY-INDEX.md`. Goal: every rendered element ✅.

Status: ✅ Rendered correctly · 🟡 Partial · ⬜ Intentionally not rendered
(metadata/scripting) · ❌ Missing (should render, doesn't).

## Main root & metadata

| Element | Status | Note |
|---|---|---|
| html | ✅ | root |
| head | ⬜ | not rendered |
| title, base, meta | ⬜ | |
| link[rel=stylesheet] | ✅ | loaded (cache/relative) |
| style | ✅ | parsed into the stylesheet |
| body | ✅ | layout root |

## Content sectioning

| Element | Status | Note |
|---|---|---|
| header, footer, main, section, article, aside | ✅ | block (generic) |
| nav | ✅ | block |
| h1–h6 | ✅ | UA sizes + weight + margin |
| hgroup | 🟡 | passes through as block |
| address | 🟡 | block; italic UA not applied |

## Text content

| Element | Status | Note |
|---|---|---|
| div | ✅ | block |
| p | ✅ | block + margins |
| ul, ol, menu | 🟡 | block + indent; **no markers** |
| li | 🟡 | block; **no bullet/number** |
| dl, dt, dd | ✅ | bold term, indented def |
| blockquote | ✅ | indent + left border |
| pre | ✅ | monospace, whitespace preserved |
| hr | 🟡 | renders as thin bordered block |
| figure, figcaption | 🟡 | block; default margins approximate |

## Inline text semantics

| Element | Status | Note |
|---|---|---|
| a | ✅ | inline; emits link events |
| span | ✅ | inline |
| b, strong | ✅ | bold |
| i, em | ✅ | italic |
| u, ins | 🟡 | underline via text-decoration |
| s, del, strike | ❌ | line-through not painted |
| small | ✅ | smaller |
| mark | 🟡 | needs yellow bg UA default |
| code, kbd, samp, var | ✅ | monospace |
| sub, sup | ❌ | no baseline shift |
| abbr, cite, dfn | ✅ | underline/italic UA |
| q | ❌ | no auto quotes |
| br | ✅ | hard break |
| wbr | ❌ | |
| bdi, bdo | ❌ | no bidi |
| time, data | 🟡 | inline text |
| ruby, rt, rp | ❌ | |

## Image & multimedia

| Element | Status | Note |
|---|---|---|
| img | ✅ | HTTPS fetch + decode + cache + aspect |
| qrcode | ✅ | **Tina4 custom** — pure-Pascal QR encoder (byte mode, v1–v10 ECC-L), painted as modules; `value`/`data` attr or text node |
| camera | ✅ | **Tina4 custom** — "Take Photo" control → shell `CaptureCamera` (still image); sets `value` |
| picture, source, srcset | ❌ | |
| svg | ❌ | not rendered |
| video, audio, track | ❌ | |
| canvas | ❌ | |
| iframe, embed, object | ❌ | |
| map, area | ❌ | |

## Table content

| Element | Status | Note |
|---|---|---|
| table | 🟡 | autosize columns; `border` attr |
| thead, tbody, tfoot | ✅ | row grouping |
| tr | ✅ | |
| td, th | 🟡 | **no colspan/rowspan** |
| caption | ❌ | |
| col, colgroup | ❌ | |

## Forms

| Element | Status | Note |
|---|---|---|
| form | ✅ | submit collects name=value |
| input[text/email/password/search/number] | ✅ | drawn, editable, caret, focus |
| input[checkbox] | ✅ | drawn + toggle |
| input[radio] | ✅ | drawn + group exclusivity |
| input[submit/button] | ✅ | drawn button |
| input[file] | ✅ | "Choose File" button → shell `PickFile` (NSOpenPanel); shows filename, sets `value` |
| input[date/color/range/…] | ❌ | fall back to text box |
| textarea | 🟡 | value shown; caret end-only |
| select, option, optgroup | ✅ | drawn + painted dropdown |
| button | ✅ | drawn; submit |
| label | 🟡 | inline; `for=` not wired to focus |
| fieldset, legend | 🟡 | border; legend not inset |
| datalist, output, progress, meter | ❌ | |

## Interactive & scripting

| Element | Status | Note |
|---|---|---|
| details, summary | ✅ | ▸/▾ marker; summary click toggles open |
| dialog | ❌ | |
| script, noscript, template | ⬜ | not executed/rendered |
| slot | ⬜ | |

## Demarcating edits & misc

| Element | Status | Note |
|---|---|---|
| onclick (attribute, any element) | ✅ | semantic event `obj:method(args)` |
| id / class / style attributes | ✅ | selectors + inline styles |
| hidden attribute | ❌ | should imply display:none — **easy win** |

## Priority element gaps

1. **List markers** (`ul`/`ol`/`li` bullets & numbers) — very common.
2. **`hidden` attribute** → display:none (trivial; answers the "HIDDEN DIV" Q).
3. **s/del/strike line-through**, **sub/sup**, **mark** bg — small paint/UA wins.
4. **colspan/rowspan** for real tables.
5. **details/summary** toggle (needs the click→state→relayout we already have).
6. Media (`svg`, `video`, `canvas`) — large, later.
