# Roadmap: native data layer (WebSockets, SSE, REST/API)

The renderer makes Tina4Pascal a *view*. The data layer makes it an *app* —
the same reach tina4js gives a browser front-end (reactive API client,
WebSocket client, live updates), but as a single native binary with no
browser and no toolkit. This is the plan; none of it is built yet.

## Design principle: HTML stays the UI, data drives it

No new widget model. Data arrives → the app mutates the DOM (attribute /
`SetInnerHTML` by id) → the renderer re-lays-out and repaints. Interaction
still surfaces as semantic events. So a live app is:

```
loop {  render(html)  <-->  events (click/submit)  <-->  data (ws/sse/api)  }
```

This mirrors tina4js's signal → re-render cycle, but the "signal" is a DOM
node and the "component" is the renderer.

## Threading model (the one hard constraint)

The UI runs a single-threaded native event loop (Cocoa `NSApp.run`, later
Win32/X11/Android). Network I/O must NOT block it. Pattern:

- I/O runs on a **worker thread** (`TThread`), using FPC's blocking sockets.
- Results marshal back to the UI thread through a **thread-safe queue** drained
  by the shell's existing **`OnTick`** callback (already implemented as
  `StartTicker` in `Tina4RenderBackend`/`Tina4ShellCocoa`). No new platform
  primitive needed — the ticker is the main-thread pump.
- Every data callback (`OnMessage`, `OnResponse`) therefore runs on the UI
  thread and may safely touch the DOM and call `Invalidate`.

`Tina4Dispatcher.Post(proc)` enqueues a closure; `Drain` (called from OnTick)
runs the queued closures on the UI thread. This single mechanism serves REST
completion, WS frames, and SSE events.

## 1. REST / API client — `Tina4Net.pas` (`TTina4API`)

Port `Tina4REST.pas` (tina4delphi) onto FPC `fphttpclient` + `fpjson`, but
**async by default** so the UI never stalls.

Delphi surface to mirror (verified in Tina4REST.pas):
`Get/Post/Put/Patch/Delete(var StatusCode; EndPoint; QueryParams; Body;
ContentType; ContentEncoding): TJSONObject`, custom headers, JSON wrapping.

Native surface:
```pascal
Api := TTina4API.Create('https://host', Dispatcher);
Api.Headers['Authorization'] := 'Bearer ' + token;
Api.Get('/users',
  procedure(Status: Integer; JSON: TJSONData)   // runs on UI thread
  begin
    Render.SetInnerHTML('userList', RenderUsers(JSON));
  end);
Api.Post('/users', body, OnDone);
```
TLS: `fphttpclient` + OpenSSL, or reuse each shell's OS stack (NSURLSession
on macOS/iOS — already used for image fetch — WinHTTP on Windows) behind one
`ITina4HttpTransport` interface so there's zero external dependency per OS.

## 2. WebSocket client — `Tina4WebSocket.pas` (`TTina4WebSocketClient`)

Port `Tina4WebSocketClient.pas` + `Tina4WebSocketFrames.pas` (both already
exist in tina4delphi — RFC 6455 framing, masking, ping/pong, close codes,
auto-reconnect with backoff). FPC `ssockets` (+ OpenSSL for `wss://`).

Delphi surface to mirror: `Connect / Disconnect(code,reason) / Send(string) /
Send(bytes) / ForceReconnect`, events `OnConnected / OnDisconnected /
OnMessage / OnReconnecting`.

Native surface:
```pascal
WS := TTina4WebSocketClient.Create('wss://host/live', Dispatcher);
WS.OnMessage := procedure(const Msg: string)     // UI thread
  begin Render.SetInnerHTML('feed', PrependRow(Msg)); end;
WS.OnConnected := procedure begin Render.SetClass('status','connected'); end;
WS.AutoReconnect := True;
WS.Connect;
```
Runs its read loop on a worker thread; frames post to the Dispatcher.

## 3. SSE client — part of `Tina4Net.pas` (`TTina4SSE`)

Server-Sent Events = a long-lived HTTP GET whose body streams
`event:`/`data:`/`id:` lines. Reuse the HTTP transport in streaming mode;
parse the line protocol; emit one event per `data:` block; honour `retry:`
and `Last-Event-ID` on reconnect.

```pascal
SSE := TTina4SSE.Create('https://host/stream', Dispatcher);
SSE.OnEvent := procedure(const EventName, Data: string) // UI thread
  begin Render.SetInnerHTML('ticker', Data); end;
SSE.Open;
```

## 4. Renderer DOM-mutation API (the reactive surface)

The data callbacks need cheap, targeted DOM updates so a message doesn't
re-parse the page. Add to the renderer (mirrors Tina4Delphi's
`TTina4HTMLRender`):

- `SetInnerHTML(id, htmlFragment)` — reparse just that subtree, relayout.
- `SetText(id, s)`, `SetAttribute(id, name, value)`, `SetClass(id, cls)`,
  `AddClass/RemoveClass/ToggleClass(id, cls)`.
- `Show(id) / Hide(id)` — the by-id visibility control (also answers the
  "HIDDEN DIV" question and the `hidden` attribute).
- `FindById` in `Tina4HTMLDom` (indexed on parse) backs all of these.

These are small and unblock live data binding; they can land before the
network clients.

## 5. Optional: signals for local reactive state — `Tina4Signal.pas`

A tiny `TSignal<T>` (value + subscriber list) mirroring tina4js `signal()`
/ `persist()`, letting app code bind a value to a DOM update without manual
plumbing. `persist()` maps to a small on-disk store (already have
`~/.cache/tina4render` precedent). Nice-to-have, not required — the DOM is
already the state store.

## Build order

1. `Tina4Dispatcher` (thread-safe queue) + wire `OnTick` to drain it.
2. Renderer DOM-mutation API + `FindById` + `Show/Hide` + `hidden` attr.
3. `TTina4API` (REST, async) on the `ITina4HttpTransport` interface
   (NSURLSession transport first — reuses the image-fetch code).
4. `TTina4SSE` (streaming transport).
5. `TTina4WebSocketClient` (port frames + client from tina4delphi).
6. `Tina4Signal` (optional sugar).
7. A `examples/live/` demo: a WS/SSE feed rendering into an HTML list,
   proving the full loop on macOS, then cross-compiled.

## Why this is achievable

- The **ticker→dispatcher** main-thread pump already exists.
- The **image pipeline** already proves per-OS network transport behind an
  abstraction (NSURLSession today).
- The **WS framing + REST client already exist in Object Pascal** in
  tina4delphi — this is a port, the same recipe as `Tina4HTMLDom`, not a
  green-field build.
