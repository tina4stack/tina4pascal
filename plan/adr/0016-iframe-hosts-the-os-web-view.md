# ADR-0016: `<iframe>` hosts the OS's own web view — the engine still has none

- **Status:** Accepted
- **Date:** 2026-10-25

## Context

The engine renders its own UI from HTML/CSS with no browser and no WebView
(ADR-0002), and ADR-0010 ruled `<iframe>` out as a way to compose *our own*
screens (`<include>` and views do that, in one native DOM).

A different need has come up: showing *external* web content inside a native
app. The motivating case is tina4-simple-agent, an AI coding harness whose agent
builds web apps and has to show a live preview of them (`http://127.0.0.1:<port>/`).
That page is someone else's HTML, CSS and JavaScript. It needs a real browser
engine, and writing one is out of scope.

The constraint from the owner: **nothing may be bundled**. No Chromium, no CEF,
no Electron. The app may only use the web view the operating system already
provides.

## Decision

`<iframe src>` is a **shell-hosted embed**, like `<video>`:

- The **engine** lays the iframe out as a sized box (HTML default 300×150, the
  `width`/`height` attributes, CSS sizing, a 2px UA frame border). It never
  parses the fallback content and never renders web content. It reports the
  iframe through the existing `TinaEmbed*` API as **kind 5**: the content-box
  rect in screen coordinates (scroll applied), `src`, and a stable
  `TinaEmbedKey` (`id`, else `iframe:<n>` in document order).
- The **shell** overlays the OS web view on that rect every frame, keeps one view
  per key, reloads it in place when `src` changes, and removes it when the
  element leaves the layout (removed, or `display:none`).

| Platform | OS web view | Status |
|---|---|---|
| macOS | `WKWebView` (WebKit.framework, part of macOS) | ✅ `Tina4ShellCocoa` |
| iOS | `WKWebView` | ⬜ planned |
| Windows | WebView2 (Evergreen runtime ships with Windows 10/11) | ⬜ planned |
| Linux | WebKitGTK (the distro's package) | ⬜ planned |
| Android | `android.webkit.WebView` (the system WebView) | ⬜ planned |

The distinction to keep straight: **the engine renders its own UI with no web
view; the OS web view is used only for embedded external web content.** It is
not a rendering path for app screens.

## Consequences

- Apps still compose their own screens with `<include>`/views (ADR-0010). An
  `<iframe>` pointing at app-owned HTML works, but it is the wrong tool: that
  content then lives in a foreign engine with no access to the native DOM,
  actions or theme.
- The web view is a native overlay, so it inherits the `<video>` overlay limits:
  it draws above engine paint (a `position:fixed` header does not clip it), it
  follows page scroll but not scrolling of an inner `overflow:auto` container,
  and `opacity`/`transform`/`border-radius` on the iframe do not apply to it.
- Snapshots (`Shell.Snapshot`, headless runs) show only the engine's white
  placeholder box. The web content lives in another process.
- macOS bundles need `NSAppTransportSecurity › NSAllowsLocalNetworking` to load
  plain `http://` from `localhost`/`127.0.0.1` (the CLI's generated Info.plists
  set it). It does not open ATS to the internet.
- Each shell that has no web view yet leaves the placeholder box showing, so a
  page with an iframe degrades safely on every platform.
- No new linked code ships with the app: the shell declares the three WKWebView
  selectors it uses (FPC 3.2.2's WebKit binding predates WKWebView) and links the
  system framework.
- If you're tempted to bundle a browser engine to "fix" one of the limits above:
  that breaks the owner's constraint and the binary-size budget. Fix it in the
  shell (clip the overlay, track inner scrollers) instead.
