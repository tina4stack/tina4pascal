# CSS property index — full coverage tracker

The exhaustive list of standard CSS properties (per the
[MDN CSS reference](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference)),
each with its status in the Tina4Pascal renderer. This is the master
checklist for "implement everything" — the goal is to move every row to ✅.

**Re-audited 2026-09-05 against the actual source** (parse in
`Tina4HTMLDom.ApplyDeclarations`, layout in `Tina4HTMLLayout`, paint in
`PaintBoxEx`). Many rows the old tracker listed as missing are in fact done
(flex, overflow-x, opacity, transform, visibility, outline, text-shadow,
text-align:justify, overline, position:sticky, cursor).

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
| aspect-ratio | ✅ | `<w>/<h>` or a bare number; with a known width and auto height the block's height is derived (width ÷ ratio). Width-from-height is the rarer case (not re-laid-out) |

## Positioning

| Property | Status | Note |
|---|---|---|
| position static/relative/absolute | ✅ | relative offsets in flow; absolute out-of-flow with top/right/bottom/left + `inset` |
| position fixed | ✅ | viewport-pinned (origin 0,0 + top/left/right); stays put on scroll |
| position sticky | ✅ | pins at `top` once scrolled past its natural spot; `top:auto` never sticks (page-scroll case; verified interactively) |
| top, right, bottom, left, inset | ✅ | consumed by relative/absolute |
| z-index | ✅ | stable paint-order sort among siblings (ties keep tree order) |
| float, clear | ✅ | `float:left/right` pins the box to the container edge; the container's in-flow inline content wraps beside it (float bands narrow each line), and `clear:left/right/both` drops a later block below the floats. Container encloses its floats (clearfix). Caveat: wrapping applies to the container's own text — text inside a *nested* block after a float doesn't yet see the parent's floats; auto-width floated blocks shrink-to-fit without re-layout |

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
| text-align | ✅ | left/center/right/justify (justify spreads slack across word gaps; last line stays left) |
| text-decoration | 🟡 | underline + line-through (native) + overline (hand-ruled); no color/style longhands |
| text-transform | ✅ | uppercase/lowercase/capitalize applied to painted glyphs |
| text-indent | ✅ | first formatted line indented (left-aligned blocks) |
| text-overflow | ✅ | ellipsis truncation (single nowrap line): truncates the crossing run + drops the rest |
| text-shadow | ✅ | painted (offset shadow pass before the glyph); see PaintBoxEx run loop |
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
| outline (+ width/style/color/offset) | ✅ | painted: stroke outside the border box, offset by outline-offset (dashed→solid) |

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
| rowspan | ✅ | column-occupancy tracked across rows; spanned height + valign resolved |
| border-collapse, border-spacing, table-layout | ❌ | not parsed; per-cell borders only |
| caption-side | ✅ | top (default) + bottom |
| empty-cells | ❌ | not parsed |
| vertical-align (cells) | ✅ | top/middle/bottom |

## UI & interaction

| Property | Status | Note |
|---|---|---|
| :hover / :active / :focus / :checked | ✅ | matcher + runtime state, end-to-end |
| appearance: none | ✅ | radios/checkboxes render as styled boxes |
| cursor | ✅ | desktop shells set the native OS pointer (pointer/text/move/grab/resize/crosshair/not-allowed/none…); inherits down the DOM. Touch shells ignore it |
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

**Done since the last audit** (each with a reftest; suite now 100/100): `@media`
+ `prefers-color-scheme`, `background-image`, gradients (linear/radial),
`box-shadow`, per-side borders, flex (shrink/justify/align-items), grid, position
fixed/relative/absolute, z-index, `font-family` + numeric weight, `text-overflow`,
`word-break`/`overflow-wrap`, `white-space`, `text-transform`/`text-indent`,
`letter-spacing`, `line-height` %/rem, and the full tables set (rowspan,
caption + caption-side, col/colgroup, tfoot-to-bottom, th bold/center).

**Quick wins — done** (outline, text-shadow, text-align:justify,
text-decoration:overline, position:sticky, cursor). Remaining longhands:
text-decoration color/style; the sub-keyword resize cursors beyond
col/row-resize.

**Outstanding — bigger rocks:**
1. **Flexbox faithfulness**: reverse directions, wrap-reverse, `align-content` /
   `align-self` / `order`, per-axis `row-gap`/`column-gap`.
2. **Grid**: explicit line placement, `grid-template-rows`/`areas`, multi-row span.
3. **calc()** `*` `/` and %/vw/vh terms; **clamp() / min() / max() / env()** (all 0 today).
4. **border-collapse / border-spacing / table-layout / empty-cells**.
5. **transitions / animations** + `@keyframes` (needs the ticker + a timeline);
    `@supports` / `@import`.
6. **transform** skew/matrix/3d + `transform-origin` / `perspective`; **filter /
    backdrop-filter / clip-path / mask**; blend-modes.
7. Typography long tail: `font`/`font-variant`/`font-stretch` shorthands,
    `word-spacing`, `direction`/`writing-mode` (bidi), `list-style` shorthand +
    position/image, `vertical-align` text-top/bottom/length.
8. **accent-color / caret-color**; **pointer-events / user-select / resize**.

**Float follow-ups (v1 caveats):** propagate a container's float bands into
nested block children's inline flow (so text inside a `<p>` after a float wraps
too); re-layout auto-width floated blocks at their shrink-to-fit width.

Each item ships with a reftest under `examples/compliance/` and flips its row
here and in `CONFORMANCE.md`.
