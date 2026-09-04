# Tina4Pascal SDK — cheatsheet

One engine, five targets. You write **HTML + CSS** for the UI and **Pascal
handlers** for behaviour; the native renderer draws every pixel (no OS widgets)
and hands you back **semantic events**. This is the whole SDK on one page.

---

## The mental model

```
HTML string  ─parse→  DOM  ─layout→  boxes  ─paint→  native canvas (Core Text / android.graphics / AppKit)
     ▲                                                        │
     └────────── your Pascal handler mutates the DOM ◀── tap / type / event
```

- **No widgets.** The UI is HTML. There is no `TButton`.
- **State lives in your app.** Change it, mutate the DOM (or re-render the HTML),
  and the next frame repaints.
- **Interaction is semantic.** A tap becomes `onclick="Object:Method(args)"`,
  not a button reference.

---

## Minimal app

Desktop (macOS) — the raw pattern (`examples/counter/counter.pas`):

```pascal
uses Tina4HTMLDom, Tina4RenderBackend, Tina4ShellCocoa, Tina4HTMLLayout;
// parse HTML → THTMLParser; build → TLayoutEngine.Build(root, width);
// paint → PaintBox(canvas, root, scrollY);  hit-test → HitTest(root, x, y)
```

Mobile / the shared runtime — you rarely touch layout directly; the engine in
**`Tina4Interact`** owns document, scrolling, focus, the caret and the
`<select>` dropdown. A shell (Android JNI / iOS C-ABI) feeds it:

```pascal
TinaInit(Canvas);          // once, with the native canvas
TinaSetHtml(html);         // or '@demo'
TinaFrame(wPx, hPx, density);   // per frame (after Canvas.BeginFrame)
TinaTouch(action, x, y);   // 0=down 1=up 2=move → TINA_* code
TinaKey(codepoint);        // 8=backspace 10=newline
```

---

## Actions (the app model)

HTML declares intent; Pascal registers the behaviour.

```html
<span onclick="Counter:Inc()">+</span>
<span class="big" id="count">0</span>
```

```pascal
uses Tina4Events;

procedure Inc_(const Args: string);
begin
  GCount := GCount + 1;
  SetElemText(FindById(Root, 'count'), IntToStr(GCount));  // mutate the DOM
  // engine relays out on the next frame
end;

RegisterAction('Counter:Inc', @Inc_);   // name = "Object:Method"
```

- `DispatchAction('Counter:Inc()')` parses the name + args and calls the handler.
- Form controls carry their own state in the DOM: a checkbox's `checked`, an
  input's `value`, a select's `value` — read/write those attributes.

---

## HTML / CSS you can use

Blocks & inline, flexbox (`display:flex`, `gap`, `align-items`, `flex-wrap`),
`position:relative/absolute`, margins/padding/border/border-radius, box-shadow,
linear-gradient, `transform: rotate/scale`, `overflow:auto` scrollers, tables,
lists, `vertical-align`, text-transform, and web-standard form controls:
`input` (text/checkbox/radio/file), `textarea`, `select/option`, `button`.
Media: `img` (+ `srcset`/`<picture>`), `svg`, `qrcode`, `camera`.

Conformance is tracked by the reftest suite (`tina4pascal compliance`,
currently 73/73 vs Chrome). Not yet: `position:sticky`, grid, floats.

---

## Services (data layer)

Portable, pure Pascal — call from a handler, then mutate the DOM.

```pascal
uses Tina4Services;

// in-memory cache with TTL (seconds; 0 = forever)
CachePut('user', json, 300);
if CacheGet('user', v) then ...        // False once expired
CacheSweep;                            // drop expired now

// persistent localStore (survives relaunch)
StoreInit(DataDir);                    // once, shell's writable dir
StoreSet('token', 'abc123');
token := StoreGetDef('token', '');
StoreDelete('token');
```

### HTTP / API (async)

Fetches and pushes (REST) without blocking the UI. A request runs on a worker
thread; the result is queued and your callback fires **on the main thread** from
`HttpPump` (which the shell calls each frame) — so the callback may touch the DOM
like a tap handler.

```pascal
uses Tina4Http, Tina4HttpFPC;   // desktop backend (OpenSSL); mobile uses native TLS

InstallFPCHttp;                 // once (desktop). App needs cthreads on Unix.
HttpGet('https://api…/thing', @OnThing);
HttpPost('https://api…/thing', json, 'application/json', @OnSaved);
// HttpRequest('PUT'|'DELETE'|…, url, body, ctype, @cb) for the rest

procedure OnThing(const R: TTina4HttpResponse);
begin
  if R.Ok then SetElemText(FindById(Root,'x'), R.Body)   // R.Status / R.Body / R.Error
  else ...;
end;
```

**TLS by platform (this is deliberate):** desktop = FPC + OpenSSL
(`Tina4HttpFPC`); **iOS/Android = the platform's native stack** (NSURLSession /
HttpURLConnection) — so there's **no OpenSSL to ship on mobile**, which sidesteps
the Android SSL grief. macOS dev needs `brew install openssl` for the desktop
backend.

### Roadmap

`WebSocket.Connect` (shell-delegated, same pump model), remote `<link>` CSS +
theme distribution and `<embed src>` (both ride on HTTP + cache), and a document
store. **Storage:** default to the pure-Pascal KV/document store (zero
dependency, identical on every target); reach for **SQLite only as the vendored
amalgamation** (compile `sqlite3.c` in — no system/NDK lib) when you need real
SQL. Don't link the OS's system sqlite (fine on Apple, painful on Android).

---

## Build · run · ship (the CLI)

```sh
tina4pascal doctor                 # toolchain report (FPC targets, Android, iOS)
tina4pascal setup all              # fetch what's missing

tina4pascal build <target>         # macos | windows | linux | android | ios | all
tina4pascal test                   # DOM + QR + SVG + services unit suites
tina4pascal compliance             # W3C reftests vs Chrome
tina4pascal run  page.html         # open the macOS viewer
tina4pascal snapshot in.html out.png

tina4pascal deploy                 # Android: .so + APK + install + launch
tina4pascal ios                    # iOS: engine + xcodebuild(sign) + install + launch
tina4pascal screenshot out.png [android|ios]
tina4pascal logcat -f              # Android native log (tag tina4)
```

---

## Targets & size

macOS · Windows · Linux · Android · iOS — **one core, one shell each**. Shipping
size is tiny: **~613 KB** Android APK, **~1.5 MB** iOS app — the whole engine
(layout, QR, SVG, canvas) statically linked, a fraction of a stock Xcode /
Android-Studio app.

Architecture rule: `src/Tina4*Dom/Layout/Interact/Services` stay pure Pascal and
talk only to the `Tina4RenderBackend` contract — anything OS-specific lives in a
shell (`Tina4Shell*`). That is what keeps one codebase building for five OSes.
```
