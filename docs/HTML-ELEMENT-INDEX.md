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
| ul, ol, menu | ✅ | block + indent + markers (disc/decimal/roman via list-style-type) |
| li | ✅ | block + bullet/number marker |
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
| u, ins | ✅ | underline via text-decoration |
| s, del, strike | ✅ | line-through painted (tfsStrike) |
| small | ✅ | smaller |
| mark | ✅ | yellow bg UA default |
| code, kbd, samp, var | ✅ | monospace |
| sub, sup | ✅ | baseline shift + smaller |
| abbr, cite, dfn | ✅ | underline/italic UA |
| q | ✅ | auto “ ” quotes |
| br | ✅ | hard break |
| wbr | ❌ | |
| bdi, bdo | ❌ | no bidi |
| time, data | 🟡 | inline text |
| ruby, rt, rp | ❌ | |

## Image & multimedia

| Element | Status | Note |
|---|---|---|
| img | ✅ | HTTPS fetch + decode + cache + aspect |
| svg | ✅ | pure-Pascal vector painter (`Tina4SVG`): g, rect(rx), circle, ellipse, line, polyline, polygon, path (M L H V C S Q T A Z), text; fill/stroke/opacity/transform/viewBox. No gradients/clip/filters/`<use>` yet |
| qrcode | ✅ | **Tina4 custom** — pure-Pascal QR encoder (byte mode, v1–v10 ECC-L), painted as modules; `value`/`data` attr or text node |
| camera | ✅ | **Tina4 custom** — "Take Photo" control → shell `CaptureCamera` (still image); sets `value` |
| picture, source, srcset | ✅ | responsive selection: `<source>` media + type filtering, srcset density (1x) + width descriptors, `sizes`; falls back to `<img src>` |
| video, audio, track | ❌ | per-OS media, belongs in the shells |
| canvas | ❌ | inert without a script/draw hook |
| iframe, embed, object | ❌ | |
| map, area | ❌ | |

## Table content

| Element | Status | Note |
|---|---|---|
| table | 🟡 | autosize columns; `border` attr |
| thead, tbody, tfoot | ✅ | row grouping |
| tr | ✅ | |
| td, th | 🟡 | colspan ✅; **rowspan** not yet |
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
| hidden attribute | ✅ | implies display:none |

## Priority element gaps

1. **table rowspan** (colspan done); `<caption>`, `<col>/<colgroup>`.
2. **Forms**: `input[date/color/range]`, `datalist`, `output`, `progress`, `meter`;
   `label[for=]` → focus; textarea multi-line caret.
3. **SVG** advanced: gradients, clip/mask, `<use>`, `<tspan>` positioning, dash arrays.
4. **dialog**; inline `wbr`, `bdi/bdo`, `ruby`.
5. Media (`video`, `audio`) — per-OS, lives in the shells; `canvas` needs a draw hook.
6. On-device shells: **Android** shell shipped (`Tina4ShellAndroid` →
   `libtina4.so`, see `android/`); **iOS** (UIKit) still to do.
