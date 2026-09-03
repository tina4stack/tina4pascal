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
| ul, ol, li | 🟡 | block + indent; markers/numbers not drawn yet |
| table, tr, td, th, thead, tbody, tfoot | 🟡 | column autosizing, `border`; no colspan/rowspan |
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
| background (gradient) | 📦 | linear-gradient parsed, not painted |
| font-size | ✅ | px, pt, em, rem, % |
| font-weight | 🟡 | bold/normal only (no numeric weights → SF weight) |
| font-style | ✅ | italic |
| font-family | 🟡 | stored; canvas maps to system/monospace bucket |
| text-decoration | ✅ | underline |
| text-align | ✅ | left/center/right |
| line-height | ✅ | unitless + px |
| vertical-align | 🟡 | top/baseline for inline atoms |
| letter-spacing, text-indent | 🟡 | parsed; letter-spacing not applied in measure |
| text-transform | 📦 | parsed, not applied |
| margin (+ `auto`, collapsing) | ✅ | shorthand, per-side, `0 auto` centering, sibling collapse |
| padding | ✅ | shorthand + per-side |
| border (width/style/color) | 🟡 | width+color painted; style always solid |
| border-radius (+ per-corner) | ✅ | painted via rounded rect |
| width / height | ✅ | px, %, auto, calc(), min/max |
| box-sizing | ✅ | content-box / border-box |
| display | 🟡 | block, inline, inline-block, none, list-item, table\*; no flex/grid layout |
| overflow / overflow-x/y | ✅ | auto/scroll/hidden → renderer-owned inner scroll + clip |
| white-space | 🟡 | normal + pre; nowrap partial |
| visibility | 📦 | parsed, not applied (use display:none) |
| opacity | 📦 | parsed, not applied |
| box-shadow | 📦 | parsed, not painted |
| text-shadow | 📦 | parsed, not painted |
| transform (translate/rotate/scale) | 📦 | parsed, not applied |
| outline | 📦 | parsed, not painted (focus ring is bespoke) |
| flex / flex-direction / justify / align | 📦 | parsed; no flex layout — children stack as block |
| cursor | 🟡 | parsed; no OS cursor change yet |
| list-style-type | 📦 | parsed; markers not drawn |
| CSS custom properties `var()` | ✅ | two-pass resolution |
| :hover / :active / :focus | ✅ | matched against live tag state; style-only repaint |
| @media | 🟡 | rules skipped (not applied) |

## Compliance suite: 65 / 65 green

The W3C-style reftest suite (`tools/run-compliance.sh`,
[COMPLIANCE-REPORT.md](COMPLIANCE-REPORT.md)) passes fully. Landed since the
first baseline: sRGB colour, rgba alpha, opacity, visibility:hidden,
min/max-width, font-size:%, text-transform, box-shadow, linear-gradient,
transform:translate, table sizing/height, and **flexbox** (row/column,
justify-content, align-items).

## Remaining gaps (next, beyond the suite)

1. **List markers** (`<ul>`/`<ol>` bullets & numbers).
2. **Flex wrap + grow/shrink** (current flex is single-line, item-sized).
3. **position: relative/absolute** + top/left + z-index.
4. **Table colspan/rowspan**, border-collapse borders.
5. **transform: rotate/scale** application; **real gradient** paint (vs midpoint).
6. **`font-weight` numeric** and **`letter-spacing`** in text measurement.
7. `s`/`del` line-through, `sub`/`sup`, `mark` background; the `hidden` attribute.
