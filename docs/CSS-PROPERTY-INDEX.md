# CSS property index — full coverage tracker

The exhaustive list of standard CSS properties (per the
[MDN CSS reference](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference)),
each with its status in the Tina4Pascal renderer. This is the master
checklist for "implement everything" — the goal is to move every row to ✅.

Status: ✅ Supported · 🟡 Partial · 📦 Parsed-only (in `TComputedStyle`, not
painted/laid out) · ❌ Missing. "Layer" is where the work lives:
**parse** = `Tina4HTMLDom.TComputedStyle.ApplyDeclarations`,
**layout** = `Tina4HTMLLayout`, **paint** = `PaintBox`, **canvas** = shell.

## Boxes & the box model

| Property | Status | Layer / note |
|---|---|---|
| width, height | ✅ | layout — px/%/auto/calc |
| min-width, max-width, min-height, max-height | 🟡 | parse ✅; only width clamps applied |
| margin (+ -top/right/bottom/left) | ✅ | layout — shorthand, auto, collapse |
| padding (+ 4 sides) | ✅ | layout |
| border-width/style/color (+ 4 sides) | 🟡 | style always solid; width+color painted |
| border-radius (+ 4 corners) | ✅ | paint |
| box-sizing | ✅ | layout |
| overflow, overflow-x, overflow-y | 🟡 | overflow-y ✅; **overflow-x ❌** |
| overflow-clip-margin, overflow-anchor | ❌ | |
| visibility | 📦 | parse only |
| display | 🟡 | block/inline/inline-block/none/list-item/table\*; **no flex/grid** |
| aspect-ratio | ❌ | |

## Positioning

| Property | Status | Layer / note |
|---|---|---|
| position (static/relative/absolute/fixed/sticky) | ❌ | **big gap** — only static flow |
| top, right, bottom, left | ❌ | |
| z-index | ❌ | paint order is tree order |
| float, clear | 🟡 | clear parsed; float ❌ |

## Flexbox & Grid

| Property | Status | Layer / note |
|---|---|---|
| flex, flex-grow/shrink/basis | 📦 | parse only — **no flex layout** |
| flex-direction, flex-wrap, flex-flow | 📦 | |
| justify-content, align-items, align-content, align-self | 📦 | |
| order, gap, row-gap, column-gap | ❌ | |
| grid and all grid-\* | ❌ | **not started** |

## Typography

| Property | Status | Layer / note |
|---|---|---|
| color | ✅ | parse — hex/rgb/rgba/named |
| font-size | ✅ | px/pt/em/rem/% |
| font-weight | 🟡 | bold/normal; numeric → nearest |
| font-style | ✅ | italic |
| font-family | 🟡 | stored; canvas maps to system/mono bucket |
| font, font-variant, font-stretch | ❌ | |
| line-height | ✅ | |
| letter-spacing | 🟡 | parsed; not applied in text measure |
| word-spacing | ❌ | |
| text-align | ✅ | left/center/right |
| text-align-last, text-justify | ❌ | |
| text-decoration (+ line/color/style) | 🟡 | underline only |
| text-transform | 📦 | parse only |
| text-indent | 🟡 | parsed |
| text-overflow | 📦 | parse only |
| text-shadow | 📦 | parse only |
| white-space | 🟡 | normal/pre; nowrap partial |
| word-break, overflow-wrap | 🟡 | parsed |
| vertical-align | 🟡 | top/baseline for inline atoms |
| direction, unicode-bidi, writing-mode | ❌ | LTR only |
| list-style-type/position/image | 📦 | markers not drawn |
| tab-size, hyphens, text-rendering | ❌ | |

## Backgrounds & borders

| Property | Status | Layer / note |
|---|---|---|
| background-color | ✅ | paint |
| background (shorthand) | 🟡 | color only |
| background-image | ❌ | (url/gradient) |
| background: linear-gradient() | 📦 | parsed, not painted |
| background-position/size/repeat/attachment/clip/origin | ❌ | |
| box-shadow | 📦 | parsed, not painted |
| outline (+ width/style/color/offset) | 📦 | parsed; focus ring is bespoke |

## Visual effects & compositing

| Property | Status | Layer / note |
|---|---|---|
| opacity | 📦 | parsed, not applied |
| transform | 📦 | translate/rotate/scale parsed, not applied |
| transform-origin, perspective | ❌ | |
| filter, backdrop-filter | ❌ | |
| clip-path, mask | ❌ | |
| mix-blend-mode, background-blend-mode | ❌ | |
| transition, animation and sub-props | ❌ | no animation engine |
| will-change, contain | ❌ | |

## Tables

| Property | Status | Layer / note |
|---|---|---|
| table layout (element) | 🟡 | layout — autosize; **no colspan/rowspan** |
| border-collapse, border-spacing | ❌ | |
| table-layout, caption-side, empty-cells | ❌ | |
| vertical-align (cells) | 🟡 | |

## UI & interaction

| Property | Status | Layer / note |
|---|---|---|
| cursor | 🟡 | parsed; no OS cursor change |
| pointer-events, user-select | ❌ | |
| :hover / :active / :focus (selectors) | ✅ | live state match + repaint |
| accent-color, caret-color, resize | ❌ | caret is bespoke |
| appearance | ❌ | controls always custom-drawn |

## Custom properties & functions

| Feature | Status | Layer / note |
|---|---|---|
| `--custom` properties + `var()` | ✅ | two-pass resolution |
| `calc()` | 🟡 | lengths only (+/- of supported units) |
| `@media` | 🟡 | rules skipped |
| `@font-face`, `@keyframes`, `@supports`, `@import` | ❌ | |
| `env()`, `clamp()`, `min()`, `max()` | ❌ | |

## Roadmap to 100% (dependency order)

1. **overflow-x** + bidirectional scroll (small, unblocks the scroll page).
2. **Paint the parsed-only set**: opacity, box-shadow, linear-gradient,
   visibility:hidden — all already in `TComputedStyle`, pure paint work.
3. **Flexbox** (row/column, justify/align, wrap, gap) — the single largest
   unlock for real-world CSS/Bootstrap.
4. **position: relative/absolute** + top/left + z-index paint ordering.
5. **List markers**, table colspan/rowspan, border-collapse.
6. **transform** application, then transitions/animations (needs the ticker,
   which already exists in the shell).

Each item ships with reftests under `examples/compliance/` and flips its rows
here and in `CONFORMANCE.md`.
