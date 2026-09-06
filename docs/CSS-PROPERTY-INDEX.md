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
| display grid | ✅ | grid-template-columns (px/%/fr/auto/repeat), row/column gaps, row-major auto-placement **that skips occupied cells**, explicit line placement (`grid-column/row: N`, `N / M`, `N / span S`), column + **row span**. `grid-template-rows`/`areas` still TODO (rows auto-size) |
| aspect-ratio | ✅ | `<w>/<h>` or a bare number; with a known width and auto height the block's height is derived (width ÷ ratio). Width-from-height is the rarer case (not re-laid-out) |

## Positioning

| Property | Status | Note |
|---|---|---|
| position static/relative/absolute | ✅ | relative offsets in flow; absolute out-of-flow with top/right/bottom/left + `inset` |
| position fixed | ✅ | viewport-pinned (origin 0,0 + top/left/right); stays put on scroll |
| position sticky | ✅ | pins at `top` once scrolled past its natural spot; `top:auto` never sticks (page-scroll case; verified interactively) |
| top, right, bottom, left, inset | ✅ | consumed by relative/absolute |
| z-index | ✅ | stable paint-order sort among siblings (ties keep tree order) |
| float, clear | ✅ | `float:left/right` pins the box to the container edge; in-flow inline content wraps beside it — including text inside *nested* block descendants (float bands live on the engine in absolute coords, shared across the block formatting context). `clear:left/right/both` drops a later block below the floats; container encloses its floats (clearfix). Auto-width floated blocks shrink-to-fit (measured max-content, re-laid-out). A float establishes its own BFC (its content ignores ancestor floats) |

## Flexbox & Grid

| Property | Status | Note |
|---|---|---|
| flex, flex-grow, flex-basis | ✅ | grow distributes free main space |
| flex-shrink | ✅ | weighted shrink pass on overflowing non-wrapping rows |
| flex-direction | ✅ | row/column + row-reverse/column-reverse (items reversed along the main axis) |
| flex-wrap | ✅ | wrap + wrap-reverse (lines stacked in reverse cross order); grow disabled while wrapping |
| flex-flow | ❌ | use longhands |
| justify-content | ✅ | start/center/end/space-between/around/evenly |
| align-items | ✅ | center/flex-end/stretch (the default, fills the cross axis); no baseline |
| align-self, order | ✅ | `align-self` overrides `align-items` per item (stretch/center/start/end); `order` reorders items (stable) before layout |
| align-content | ✅ | distributes wrapped lines on the cross axis (center/flex-end/space-between/space-around); stretch = default packing |
| gap, row-gap, column-gap | ✅ | per-axis: `gap: <row> <col>`; flex uses column-gap on a row / row-gap on a column |
| grid-column, grid-row | ✅ | explicit start line + span, or `N / M`; occupancy-aware auto-placement around them |
| grid-template-rows | 🟡 | explicit **px** row-track heights honored; fr/%/auto rows still content-sized |
| grid-template-areas, grid-area | ✅ | `"a a b" "a a c"` named-area template; an item's `grid-area: name` is placed at that area's bounding cell rect (row/col start + span). Single or double quotes |

## Typography

| Property | Status | Note |
|---|---|---|
| color | ✅ | hex/rgb/rgba/named/var() |
| font-size | ✅ | px/pt/em/rem/% |
| font-weight | ✅ | numeric 100–900 + keywords, threaded to the canvas; Cocoa steps the system font weight (iOS/Android binary bold for now) |
| font-style | ✅ | italic/oblique |
| font-family | ✅ | resolved on all 3 shell canvases (generic + named + @font-face); real fonts, not one system face |
| font (shorthand) | ✅ | `[style] [variant] [weight] size[/line-height] family` — sets style/weight/size/line-height/family |
| font-variant, font-stretch | 📦 | parsed-ignored (small-caps not synthesised) |
| line-height | ✅ | unitless, px, em, % (÷100), rem (×16 root) |
| letter-spacing | ✅ | applied in measure AND paint |
| word-spacing | ✅ | extra px added to every inter-word space (inherited; affects wrap + alignment) |
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
| list-style shorthand, list-style-position | ✅ | shorthand tokenised (type · inside/outside · url image ignored); `position:inside` draws the marker in the content flow. `list-style-image` still not rendered |
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
| transform: translate/rotate/scale/skew | ✅ | 2D transforms via NSAffineTransform (skew adds a shear on the shell canvas — `Skew` contract method) |
| transform: matrix/3d | ❌ | matrix() + 3D (rotateX/Y/Z, perspective) not applied |
| transform-origin | ✅ | keyword/px/% pivot for rotate/scale/skew (default 50% 50%) |
| perspective | ❌ | needs a 3D pipeline |
| filter, backdrop-filter, clip-path, mask | ❌ | |
| mix-blend-mode, background-blend-mode | ❌ | |
| animation, @keyframes | ✅ | `@keyframes` parsed; `animation` shorthand + longhands (name/duration/delay/timing/iteration/direction). Per-frame interpolation at paint off the ticker: transform (translate/rotate/scale), opacity, background-color, color; timing linear/ease/ease-in/-out; iteration + alternate/reverse |
| transition | ✅ | eases a property toward its computed value when it changes (hover/focus/DOM): background-color, color, opacity, transform (translate/rotate/scale). Per-element from/start tracked on the tag; duration/delay/timing/property from the shorthand + longhands. Mid-transition reversal supported |
| will-change, contain | ❌ | |

## Tables

| Property | Status | Note |
|---|---|---|
| table layout + colspan | ✅ | auto column sizing; colspan both passes |
| rowspan | ✅ | column-occupancy tracked across rows; spanned height + valign resolved |
| border-collapse, border-spacing | ✅ | `border-spacing` (separate model) adds gaps around + between cells (reserved from column widths, applied to colspan/rowspan too); `border-collapse:collapse` forces zero spacing / shared borders |
| table-layout | 📦 | parsed-ignored — sizing is always auto (content-based) |
| caption-side | ✅ | top (default) + bottom |
| empty-cells | ❌ | not parsed |
| vertical-align (cells) | ✅ | top/middle/bottom |

## UI & interaction

| Property | Status | Note |
|---|---|---|
| :hover / :active / :focus / :checked | ✅ | matcher + runtime state, end-to-end |
| appearance: none | ✅ | radios/checkboxes render as styled boxes |
| cursor | ✅ | desktop shells set the native OS pointer (pointer/text/move/grab/resize/crosshair/not-allowed/none…); inherits down the DOM. Touch shells ignore it |
| pointer-events | ✅ | `none` makes the box + subtree transparent to hit-testing (clicks pass through) |
| user-select, resize | 📦 | parsed-ignored — no text-selection model / drag-resize handle yet |
| accent-color | ✅ | tints checkboxes, radios, range fill/thumb, and progress fill (falls back to the theme indigo) |
| caret-color | ✅ | colours the text-input/textarea caret |

## Custom properties & functions

| Feature | Status | Note |
|---|---|---|
| `--custom` + var() | ✅ | scoped 2-pass, fallback + recursion (colours included) |
| calc() | ✅ | full expression eval: `+ − × ÷` with precedence + parens, px/em/rem/pt/vw/vh/vmin/vmax. `%` is resolved against the container for width/height (deferred to layout); in other properties a %-term is treated as 0 |
| `@media` (in `<style>`) | ✅ | min/max-width breakpoints + `prefers-color-scheme` dark (incl. dark `:root` var swaps), live via `SetMediaContext` |
| `@font-face` | ✅ | downloadable fonts: parse family + `src url()`, fetch (async/disk-cached like `<img>`) + register on all 3 shells (Cocoa/iOS CoreText, Android Typeface); CSS family aliased to the face's real name |
| `@keyframes` | ✅ | parsed into named stops; drives `animation` |
| `@supports`, `@import` | ❌ | skipped with the @-rule block |
| clamp(), min(), max() | ✅ | evaluated via the calc() engine (nestable, same unit support). `env()` still 0 |

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

**Outstanding — bigger rocks** (each needs a dedicated subsystem the immediate-
mode renderer doesn't yet have):
1. **transform** matrix()/3D + `perspective` — a 3D projection pipeline (2D
    translate/rotate/scale/skew + `transform-origin` done).
2. **filter / backdrop-filter / clip-path / mask / blend-modes** — an offscreen
    render target + image-filter/compositing pass per shell.
3. **Grid**: `grid-template-rows` fr/%/auto (px rows, template-areas, line
    placement, column/row span, occupancy auto-placement done).
4. Typography remainder: `font-variant` small-caps synthesis, `font-stretch`,
    `direction`/`writing-mode` (bidi), `list-style-image`, `vertical-align`
    text-top/bottom/length.
5. **user-select / resize** (need a selection model / drag-resize handle);
    `env()`; `table-layout:fixed`; `empty-cells`; `@supports` / `@import`.


Each item ships with a reftest under `examples/compliance/` and flips its row
here and in `CONFORMANCE.md`.
