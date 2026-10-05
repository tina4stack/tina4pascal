# ADR-0014: dynamically-added nodes animate; apps can read the viewport

- **Status:** Accepted
- **Date:** 2026-10-05

## Context

Building the app-driven hero (parallax + cursor sparkle in app code) surfaced two
gaps once `onmousemove` (ADR-0012) and the DOM-node API (ADR-0013) were in place:

1. **A CSS `@keyframes` animation on a node added at runtime never played.**
   `ApplyKeyframeAnim` computed progress as `t = (AnimClock − delay) / duration`
   using the **global** clock with no per-element start. A node appended at, say,
   clock 5.0s with a 0.62s animation was instantly past its end — for a sparkle
   (`forwards`, ends at `opacity:0`) that means invisible the moment it is spawned.
   Transitions already solved this with a per-element `_tr0_` start stamp; keyframes
   did not.
2. **An app had no way to read the viewport size**, which a cursor handler needs to
   turn `onmousemove`'s `"x,y"` into a cursor-from-centre offset without hard-coding
   a resolution.

(Also found while here: a `width:0;height:0` container has its subtree culled — so a
sparkle layer must be given a real size. That is expected engine behaviour, noted in
the hero's HTML, not an engine change.)

## Decision

- **Per-element animation start for dynamic nodes.** `Tina4Builtins.AppendChild`
  marks each appended node with a `_dyn` attribute. `ApplyKeyframeAnim(Tag, st)` now:
  a node with no `_dyn` animates against the global clock exactly as before
  (`animStart = 0` — **static content is unchanged, no reftest regression**); a
  `_dyn` node stamps `_anim0 = AnimClock` on first paint and animates relative to it
  (`t = (AnimClock − animStart − delay) / duration`). So an app-spawned node plays
  its animation from when it appears.
- **`TinaViewport(out W, H)`** (Tina4Interact) returns the current layout viewport in
  CSS px, so an app can normalise cursor coordinates resolution-free.

## Consequences

- App code can spawn animated DOM nodes that actually animate — the cursor sparkle
  (and any particle/toast effect) is now fully app-driven via `onmousemove` +
  `Tina4Builtins` + CSS `@keyframes`, no viewer hook or per-frame app callback.
- Static-content animations and the whole reftest suite are unaffected (static nodes
  keep the global-clock path). Verified: 7 unit tests + 224/224 compliance, 0 fail;
  `test_builtins_nodes` asserts the `_dyn` mark.
- `_dyn`/`_anim0` are internal underscore attributes, ignored by rendering. A node
  that finishes a `forwards` animation keeps the ticker marked active (pre-existing
  behaviour); app effects bound the DOM by retiring old nodes (the hero caps its
  sparkle trail).
- An app that wants a node added at runtime to animate on the **global** clock can
  delete its `_anim0` (or avoid `AppendChild`'s `_dyn`), but the per-element start is
  the browser-faithful default for freshly inserted elements.
