# ADR-0013: runtime DOM node primitives in Tina4Builtins

- **Status:** Accepted
- **Date:** 2026-10-05

## Context

`Tina4Builtins` let app code *find* nodes (`FindById`/`FindByName`) and set an
element's text (`SetElementText`), but gave no way to **create, append, or remove**
nodes at runtime, nor to set arbitrary attributes/inline styles from Pascal. A
cursor-driven effect (e.g. the `tina4studio` hero's sparkle trail) needs to spawn
and retire DOM nodes per frame — so that logic had to live in the example viewer
instead of in app code (ADR-0012 added `onmousemove`, but a handler had nothing to
build with).

## Decision

Add small, **agnostic** DOM-node primitives to `Tina4Builtins` — generic building
blocks the engine attaches no meaning to; the app composes effects from them:

- `CreateElement(tag)` — a detached element (not in the tree until appended).
- `AppendChild(parent, child)` — attach/move (detaches from any old parent first).
- `RemoveNode(node)` — `node.Free`; `THTMLTag`'s destructor self-detaches and frees
  the subtree, so callers never Remove-then-Free the same node.
- `SetAttr(node, name, value)` / `SetStyleProp(node, prop, value)` — write the
  element's attribute / inline-style dict (keys stored lowercase; inline style is
  highest priority in the cascade).
- `ChildCount(node)` / `ChildAt(node, i)` — read access.

Every mutation that changes the live tree sets `BuiltinsDirty`, so the host
relayouts next frame (the same dirty contract `SetElementText` already uses).

## Consequences

- App code (Pascal, via `onmousemove` or any registered action) can now build and
  tear down UI at runtime — particles, toasts, list rows — without a viewer patch
  or a rebuild. The `tina4studio` hero's sparkle/parallax can move out of the
  example viewer into app code (the next step).
- The API is deliberately **effect-agnostic**: no sparkle/particle/hero concept
  enters the engine. Keep it that way — specific behaviours belong in apps.
- Covered by `tests/test_builtins_nodes.pas` (in the compliance unit gate):
  create/append/remove, reparent/detach, attr/style writes, dirty-flag, child
  access. Full suite stays green (7 unit tests + 224/224 compliance).
- Removal frees the subtree immediately; an app holding a stale reference to a
  removed node (or its children) must drop it. This matches the self-detaching
  destructor already relied on across the DOM.
