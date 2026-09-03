# Tina4Pascal rendering conformance

The systematic tracker for HTML element and CSS property support in the
native renderer (`Tina4HTMLDom` + `Tina4HTMLLayout`). This is the source of
truth for "what works": every row is backed by the code and by
`examples/htmlviewer/conformance_test.html`, checked against headless Chrome
/ Safari at the same viewport.

Status legend:
- ✅ **Supported** — parsed, laid out, and painted correctly
- 🟡 **Partial** — parsed and mostly works, with the noted limitation
- 📦 **Parsed-only** — read into the computed style but NOT yet painted
- ❌ **Missing** — not handled

## Method (how we close gaps)

1. Add the case to `conformance_test.html` (one row per feature).
2. Snapshot ours (`htmlviewer --script`) and Chrome (`--headless --screenshot`)
   at 1024px; diff visually.
3. Fix in the correct layer — the box model / display / painting in
   `Tina4HTMLLayout`, the property parse in `Tina4HTMLDom.TComputedStyle`.
   Never special-case an element in the layout engine when a UA-stylesheet
   default (in `ForTag`) is the right home.
4. Flip the row here; add an assertion to `tests/test_dom.pas` when it's
   parse-level.

## HTML elements

| Element | Status | Notes |
|---|---|---|
| html, body | ✅ | body is the layout root |
| head, title, meta, script | ✅ | skipped (not rendered) |
| style, link[rel=stylesheet] | ✅ | `<style>` parsed; `<link>` from cache/relative |
| div, p, section, article, header, footer, main, nav | ✅ | block |
| span, a, b, strong, i, em, small, u, mark | ✅ | inline; `a` emits link events |
| h1–h6 | ✅ | UA sizes + bold + margins |
| ul, ol, li | ✅ | markers + all list-style-type variants (bullet/number/alpha/roman) |
| table, tr, td, th, thead, tbody, tfoot | 🟡 | autosize, `border`, colspan, cell vertical-align; no rowspan |
| img | ✅ | HTTPS fetch + decode + cache; intrinsic size; aspect scale |
| br | ✅ | hard line break |
| hr | 🟡 | renders as a bordered block; thin rule styling approximate |
| pre, code, kbd, samp, var | ✅ | monospace; `pre` preserves whitespace |
| blockquote | ✅ | indent + left border |
| form | ✅ | groups controls; submit collects name=value |
| input[text/email/password/search/number] | ✅ | drawn field, caret, editing, focus ring |
| input[checkbox] | ✅ | drawn box + tick, toggles `checked` |
| input[radio] | ✅ | drawn dot; group exclusivity by `name` |
| input[submit], button | ✅ | drawn button; fires submit |
| textarea | 🟡 | multi-line value; caret is end-only, no wrap editing |
| select, option | ✅ | drawn field + painted dropdown overlay + change event |
| label | ✅ | inline; `for=` focus association not wired |
| fieldset, legend | 🟡 | fieldset border; legend not inset |
| dl, dt, dd | ✅ | bold term, indented definition |

## CSS properties

| Property | Status | Notes |
|---|---|---|
| color | ✅ | named, #hex, rgb/rgba |
| background-color | ✅ | incl. alpha |
| background (gradient) | 🟡 | linear-gradient painted as midpoint (not a real ramp) |
| font-size | ✅ | px, pt, em, rem, % |
| font-weight | 🟡 | bold/normal (no numeric weights) |
| font-style | ✅ | italic |
| font-family | 🟡 | stored; canvas maps to system/monospace bucket |
| text-decoration | ✅ | underline |
| text-align | ✅ | left/center/right |
| line-height | ✅ | unitless + px |
| vertical-align | ✅ | baseline/top/middle inline; sub/super; table-cell top/middle/bottom |
| letter-spacing | ✅ | applied in measure + paint (kerning) |
| text-transform | ✅ | uppercase/lowercase/capitalize |
| margin (+ `auto`, collapsing) | ✅ | shorthand, per-side, `0 auto` centering, sibling collapse |
| padding | ✅ | shorthand + per-side |
| border (width/style/color) | 🟡 | width+color painted; style always solid |
| border-radius (+ per-corner) | ✅ | painted via rounded rect |
| width / height | ✅ | px, %, auto, calc(), min/max |
| box-sizing | ✅ | content-box / border-box |
| position | 🟡 | relative + absolute/fixed (top/left/right/bottom); no z-index/sticky |
| display | ✅ | block, inline, inline-block, none, list-item, table, **flex**; no grid |
| overflow / overflow-x/y | ✅ | auto/scroll/hidden → renderer-owned inner scroll + clip |
| white-space | ✅ | normal, pre, nowrap (nowrap keeps one line) |
| visibility | ✅ | hidden hides self+subtree, keeps space |
| opacity | ✅ | multiplied down the subtree |
| box-shadow | ✅ | offset+spread painted (blur hard-edged) |
| text-shadow | 📦 | parsed, not painted |
| transform (translate/rotate/scale) | ✅ | real canvas transform incl. subtree |
| outline | 📦 | parsed, not painted (focus ring is bespoke) |
| flex (direction/justify/align/grow/basis/wrap) | ✅ | row/column, single- and multi-line |
| cursor | 🟡 | parsed; no OS cursor change yet |
| list-style-type | ✅ | disc/circle/square/decimal/alpha/roman/none |
| CSS custom properties `var()` | ✅ | two-pass resolution |
| :hover / :active / :focus | ✅ | matched against live tag state; style-only repaint |
| @media | 🟡 | rules skipped (not applied) |

## Compliance suite: 71 / 71 green

The W3C-style reftest suite (`tools/run-compliance.sh`,
[COMPLIANCE-REPORT.md](COMPLIANCE-REPORT.md)) passes fully. Landed across the
push: sRGB colour, rgba alpha, opacity, visibility:hidden, min/max-width,
font-size:%, text-transform, box-shadow, linear-gradient, table
sizing/height/**colspan**/**cell vertical-align**, **flexbox**
(row/column, justify-content, align-items, **flex-grow/basis**, **flex-wrap**),
**list markers + all list-style-type variants**, **white-space:nowrap +
overflow-x** (with drag/momentum scroll), **true baseline alignment**,
**sub/sup**, **letter-spacing**, **position relative/absolute**, and real
**transform translate/rotate/scale**.

## Remaining gaps (next)

1. **Table rowspan** (colspan done); border-collapse collapsed borders.
2. **Real gradient paint** (currently midpoint fill — a real gradient can't be
   reftested against primitives, so it's a visual-only change).
3. **`font-weight` numeric** (canvas is bold/normal only).
4. **Flex shrink**, `align-self`, `align-content`, gaps.
5. **z-index** (paint order is currently tree order); `position: sticky`.
6. `@media` application; CSS `transition`/`animation`.
