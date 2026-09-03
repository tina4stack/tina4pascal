# Tina4Pascal codebase map

Repo: https://github.com/tina4stack/tina4pascal

## src/ — the stack

| File | Layer | Contents |
|---|---|---|
| `Tina4HTMLDom.pas` | core | `THTMLTag` (DOM), `THTMLParser` (HTML → DOM, collects `<style>` blocks + `<link>` hrefs), `TCSSRule`/`TCSSStyleSheet` (indexed cascade, specificity, `:hover/:active/:focus` vs tag state flags, attribute selectors, `var()` resolution), `TEdgeValues`, `TBoxShadow`, `TComputedStyle` (`Default`, `ForTag` = full cascade incl. UA defaults + Bootstrap `.btn` fallback, `ParseColor`, `ParseLength` incl. calc/rem/em/px/pt/%/auto). ~3100 lines ported from Tina4Delphi `Tina4HTMLRender.pas` — keep method names/behaviour in sync. |
| `Tina4HTMLLayout.pas` | core | `TLayoutBox` tree, `TLayoutEngine` (block stacking, inline flow with wrapping, atomic inline-blocks, tables, image boxes, % widths, box-sizing, `margin:0 auto`, sibling margin collapse), `PaintBox` (display-list style painting incl. rounded rects, images), `HitTest`. Only talks to `TTina4Canvas`. |
| `Tina4RenderBackend.pas` | contract | `TTina4Canvas` (Fill/Stroke/RoundRect, DrawLine, DrawText/MeasureText, clip, LoadImage/ImageSize/DrawImage with no-op defaults), `TTina4Shell` (Initialize/Invalidate/Run/Quit, OnPaint/Mouse/Scroll/Resize, GetMeasuringCanvas). Colors `$AARRGGBB`, CSS-pixel coords, top-left origin. |
| `Tina4ShellCocoa.pas` | shell (macOS) | NSWindow + flipped NSView, AppKit text, NSData/NSImage HTTPS image pipeline with `~/.cache/tina4render/` disk cache, precise trackpad scroll deltas, `SnapshotPath` self-screenshot (seed of headless PNG mode). |

## examples/htmlviewer/

`htmlviewer.pas` — the reference app: parse file → stylesheet (linked CSS from
`csscache/` for remote URLs, relative files directly) → layout at window width
→ paint with scroll offset → semantic click events on stdout.
`bootstrap_test.html` is the acceptance page (nav, alert, cards, table,
Bootstrap buttons, remote images). Prefetch CSS:
`curl -sL -o csscache/bootstrap.min.css https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css`

## tests/

`test_dom.pas` — 113 assertions over parsing, selectors, specificity,
pseudo-classes, entities, var(), computed styles. Gate: prints
`ALL TESTS PASS`, exit 0. Extend it with revert-detecting assertions for
every DOM/CSS change.

## toolchain/ and docs/

`toolchain/build-crosses.sh` — builds all cross-compilers into `~/fpc`.
`docs/TOOLCHAIN.md` (= references/build-formula.md) — the pitfall formula.
`docs/ARCHITECTURE.md` — layering, software-rasterizer plan, app model.

## Upstream sibling

tina4stack/tina4delphi `Tina4HTMLRender.pas` (13k lines, FMX) is the
reference renderer. Not yet ported: TFileCache/TImageCache, TLayoutEngine
(FMX one), native form controls, WebSocket/REST units (planned data layer).
Known upstream bug found during porting: `TComputedStyle.ForTag` never sets
`BoxShadow.Active` (uninitialised).
