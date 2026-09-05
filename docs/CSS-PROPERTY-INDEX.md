# CSS property index — full coverage tracker

The exhaustive list of standard CSS properties (per the
[MDN CSS reference](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference)),
each with its status in the Tina4Pascal renderer. This is the master
checklist for "implement everything" — the goal is to move every row to ✅.

**Re-audited 2026-09-05 against the actual source** (parse in
`Tina4HTMLDom.ApplyDeclarations`, layout in `Tina4HTMLLayout`, paint in
`PaintBoxEx`). Many rows the old tracker listed as missing are in fact done
(flex, overflow-x, opacity, transform, visibility); several it listed as
supported are only parsed (font-family, text-shadow, text-indent, outline).

Status: ✅ Supported · 🟡 Partial (caveat noted) · 📦 Parsed-only (in
`TComputedStyle`, never laid out/painted) · ❌ Missing (not parsed).

## Boxes & the box model

| Property | Status | Note |
|---|---|---|
| width, height | ✅ | px/%/auto, box-sizing-aware |
| min-width, max-width | ✅ | clamped in layout |
| min-height, max-height | ✅ | clamped in LayoutBlock |
| margin (+ 4 sides) | ✅ | shorthand, auto-center, vertical collapse |
| padding (+ 4 sides) | ✅ | |
| border-width (+ 4 sides) | ✅ | per-side widths painted (rectangular boxes); rounded boxes use a uniform stroke |
| border-style (+ 4 sides) | ✅ | solid / dashed / dotted / double painted (rectangular boxes); groove/ridge/inset/outset → solid |
| border-color (+ 4 sides) | ✅ | per-side colours painted (rectangular boxes) |
| border-radius (+ 4 corners) | ✅ | 1–4 shorthand + per-corner |
| box-sizing | ✅ | content-box/border-box |
| overflow, overflow-x, overflow-y | ✅ | both axes scroll+clip (tracker's "overflow-x ❌" was stale) |
| visibility | ✅ | hidden hides self+subtree, keeps space (was mislabelled 📦) |
| display block/inline/inline-block/none/list-item/table | ✅ | |
| display flex / inline-flex | ✅ | LayoutFlex (was mislabelled "no flex") |
| display grid | ✅ | grid-template-columns (px/%/fr/auto/repeat), row/column gaps, row-major auto-placement, grid-column/row: span N; auto rows |
| aspect-ratio | ❌ | not parsed |

## Positioning

| Property | Status | Note |
|---|---|---|
| position static/relative/absolute | ✅ | relative offsets in flow; absolute out-of-flow with top/right/bottom/left + `inset` |
| position fixed | ✅ | viewport-pinned (origin 0,0 + top/left/right); stays put on scroll |
| position sticky | 📦 | parsed, falls back to static |
| top, right, bottom, left, inset | ✅ | consumed by relative/absolute |
| z-index | ✅ | stable paint-order sort among siblings (ties keep tree order) |
| float, clear | 📦 | parsed, no float/clear layout |

## Flexbox & Grid

| Property | Status | Note |
|---|---|---|
| flex, flex-grow, flex-basis | ✅ | grow distributes free main space |
| flex-shrink | ✅ | weighted shrink pass on overflowing non-wrapping rows |
| flex-direction | 🟡 | row/column; reverse variants not reversed |
| flex-wrap | 🟡 | wrap works; wrap-reverse = plain wrap; grow disabled while wrapping |
| flex-flow | ❌ | use longhands |
| justify-content | ✅ | start/center/end/space-between/around/evenly |
| align-items | ✅ | center/flex-end/stretch (the default, fills the cross axis); no baseline |
| align-content, align-self, order | ❌ | no multi-line cross-align, per-item align, or reorder |
| gap, row-gap, column-gap | 🟡 | one shared gap value (no per-axis distinction) |
| grid-template-columns, gap, grid-column span | ✅ | see display grid. TODO: explicit line placement, grid-template-rows/areas, multi-row span |

## Typography

| Property | Status | Note |
|---|---|---|
| color | ✅ | hex/rgb/rgba/named/var() |
| font-size | ✅ | px/pt/em/rem/% |
| font-weight | ✅ | numeric 100–900 + keywords, threaded to the canvas; Cocoa steps the system font weight (iOS/Android binary bold for now) |
| font-style | ✅ | italic/oblique |
| font-family | ✅ | resolved on all 3 shell canvases (generic + named + @font-face); real fonts, not one system face |
| font (shorthand), font-variant, font-stretch | ❌ | not parsed |
| line-height | ✅ | unitless, px, em, % (÷100), rem (×16 root) |
| letter-spacing | ✅ | applied in measure AND paint |
| word-spacing | ❌ | |
| text-align | 🟡 | left/center/right; **justify falls back to left** |
| text-decoration | 🟡 | underline + line-through; no overline; no color/style longhands |
| text-transform | ✅ | uppercase/lowercase/capitalize applied to painted glyphs |
| text-indent | ✅ | first formatted line indented (left-aligned blocks) |
| text-overflow | ✅ | ellipsis truncation (single nowrap line): truncates the crossing run + drops the rest |
| text-shadow | 📦 | fully parsed, never rendered |
| white-space | ✅ | normal/nowrap/pre/pre-wrap/pre-line; pre* preserve newlines (+ spaces for pre/pre-wrap) — parser keeps raw text for <pre> and inline white-space:pre* |
| word-break, overflow-wrap | ✅ | break-word/break-all/anywhere: over-long words break between characters (UTF-8 aware) |
| vertical-align | 🟡 | sub/super/top/middle; no text-top/bottom/length |
| list-style-type | ✅ | disc/circle/square/decimal/alpha/roman/none |
| list-style-position/image, list-style shorthand | 🟡/❌ | shorthand mis-parses multi-token; position/image absent |
| direction, unicode-bidi, writing-mode | ❌ | LTR only |
| tab-size, hyphens, text-rendering, text-align-last, text-justify | ❌ | |

## Backgrounds & borders

| Property | Status | Note |
|---|---|---|
| background-color | ✅ | alpha-scaled by opacity |
| background (shorthand) | 🟡 | color channel only |
| background-image: url() | ✅ | painted via the cached/async image path; size cover/contain/auto, position, repeat; clipped |
| background: linear-gradient() | ✅ | real multi-stop gradient (up to 8 stops + positions), angle honored; backend NSGradient on Cocoa (base fallback = flat avg) |
| background: radial-gradient() | ✅ | parsed + painted (center radial); shape/size keywords accepted, not yet modelled |
| box-shadow | ✅ | soft blur (NSShadow) + spread + corner-radius aware, outset; inset still TODO |
| outline (+ width/style/color/offset) | 📦 | fully parsed, **never painted** (focus ring is bespoke) |

## Visual effects & compositing

| Property | Status | Note |
|---|---|---|
| opacity | ✅ | subtree alpha via ScaleAlpha (per-channel, not group compositing) |
| transform: translate/rotate/scale | ✅ | real NSAffineTransform about box centre |
| transform: skew/matrix/3d | ❌ | silently skipped |
| transform-origin, perspective | ❌ | rotate/scale always pivot centre |
| filter, backdrop-filter, clip-path, mask | ❌ | |
| mix-blend-mode, background-blend-mode | ❌ | |
| transition, animation | ❌ | no animation engine (ticker exists) |
| will-change, contain | ❌ | |

## Tables

| Property | Status | Note |
|---|---|---|
| table layout + colspan | ✅ | auto column sizing; colspan both passes |
| rowspan | ❌ | multi-row cells collapse |
| border-collapse, border-spacing, table-layout | ❌ | not parsed; per-cell borders only |
| caption-side, empty-cells | ❌ | `<caption>` dropped |
| vertical-align (cells) | ✅ | top/middle/bottom |

## UI & interaction

| Property | Status | Note |
|---|---|---|
| :hover / :active / :focus / :checked | ✅ | matcher + runtime state, end-to-end |
| appearance: none | ✅ | radios/checkboxes render as styled boxes |
| cursor | 📦 | parsed, no OS cursor set |
| pointer-events, user-select, resize | ❌ | |
| accent-color, caret-color | ❌ | hard-coded to theme accent |

## Custom properties & functions

| Feature | Status | Note |
|---|---|---|
| `--custom` + var() | ✅ | scoped 2-pass, fallback + recursion (colours included) |
| calc() | 🟡 | additive only (+/-); **no \* /**, drops %/vw/vh terms |
| `@media` (in `<style>`) | ✅ | min/max-width breakpoints + `prefers-color-scheme` dark (incl. dark `:root` var swaps), live via `SetMediaContext` |
| `@font-face` | ✅ | downloadable fonts: parse family + `src url()`, fetch (async/disk-cached like `<img>`) + register on all 3 shells (Cocoa/iOS CoreText, Android Typeface); CSS family aliased to the face's real name |
| `@keyframes`, `@supports`, `@import` | ❌ | skipped with the @-rule block |
| env(), clamp(), min(), max() | ❌ | evaluate to 0 |

## Prioritised roadmap (by real-world impact ÷ effort)

**Quick wins (parsed already — pure paint/wire):**
1. **`@media` rules** — wire the existing `EvalMediaQuery` into `ParseCSS`/cascade → dark-mode `prefers-color-scheme` (**the color-vars fix**) + responsive breakpoints.
2. **outline** paint (mirror the border stroke, offset outward) — focus rings.
3. **background-image: url()** paint (fetch/cache path already exists for `<img>`).
4. **box-shadow** soft blur + inset + radius-aware.
5. **min-height / max-height** clamp; **per-side border width/color + border-style** (dashed/dotted) paint.
6. **details/summary** tap-toggle (HTML) — ubiquitous accordion.

**Bigger rocks:**
7. **Flexbox faithfulness**: flex-shrink pass, align-items:stretch, align-content/self/order.
8. **position: fixed/sticky** (viewport-pinned) + **z-index** paint ordering.
9. **font-family** through the canvas (system/serif/mono/named buckets) + numeric font-weight.
10. **Real gradients** (linear angle + multi-stop, radial) via a backend gradient op.
11. **text-overflow: ellipsis**, **overflow-wrap/word-break**, **white-space: pre-wrap**.
12. **calc()** \*// + %; **clamp()/min()/max()/env()**.
13. **Grid** (the largest single unlock after the above).
14. **transitions/animations** (needs the ticker + a timeline).

Each item ships with a reftest under `examples/compliance/` and flips its row
here and in `CONFORMANCE.md`.
