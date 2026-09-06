# Your first Tina4Pascal app

Zero to a running, native app in a few minutes. You'll write HTML for the look
and a few lines of Pascal for the behaviour — the renderer draws it natively and
the same code ships to macOS, Windows, Linux, Android and iOS.

## 0. One-time setup

```sh
git clone <repo> tina4pascal && cd tina4pascal
tools/tina4pascal setup all      # fetches FPC targets + Android/iOS tooling
tools/tina4pascal doctor         # green ticks = you're ready
```

Put `tools/tina4pascal` on your PATH (or call it with the path) and you're set.

### On Windows (PowerShell)

Everything below has a native Windows equivalent — use `tools\tina4pascal.ps1`
and the `init` / `build` / `run` verbs:

```powershell
tools\tina4pascal.ps1 doctor        # FPC, WSL/Linux, Android chain, JDK
tools\tina4pascal.ps1 init hello    # scaffold + build + open a native window
cd hello
..\tools\tina4pascal.ps1 build android   # signed APK — see below
```

No Mac and no WSL are needed to ship an Android APK from Windows; run
`tools\tina4pascal.ps1 setup android` once (it fetches the NDK and builds the
FPC Android cross), then `build android`. Details in
[../android/README.md](../android/README.md).

## 1. Scaffold an app

```sh
tina4pascal new hello
cd hello
tina4pascal dev            # builds + opens a native window
```

You get a working counter: a big number and two buttons, and the count is
**remembered across restarts**. Two files:

- **`app.html`** — the UI. Ordinary HTML + CSS. `{{count}}` is a placeholder.
- **`main.pas`** — ~60 lines: the state, the render loop, and your handlers.

## 2. Change the look — edit `app.html`

It's just HTML/CSS. Change the colour, the copy, add a card:

```html
<h1>{{count}}</h1>
<p>taps so far</p>
<span class="btn2" onclick="App:Down()">–</span>
<span class="btn"  onclick="App:Up()">+</span>
```

Re-run `tina4pascal dev` to see it. (Styling in a `<style>` block, inline
`style="…"`, flexbox, images, `qrcode`, `svg` — all work. See the
[cheatsheet](CHEATSHEET.md).)

## 3. Add behaviour — edit `main.pas`

A tap on `onclick="App:Up()"` runs the proc you registered under that name:

```pascal
procedure Up(const Args: string);
begin
  Inc(Count);
  StoreSet('count', IntToStr(Count));   // persist (localStore service)
end;

RegisterAction('App:Up', @Up);          // wire the name to the proc
```

That's the whole model: **HTML declares intent, Pascal handles it, state
changes, the screen re-renders.** Add a new button in `app.html`, register a new
`App:Something` proc, done. Read data with `CacheGet`/`StoreGet`; put a value on
screen by interpolating it into the HTML (or, on device, by setting a DOM
attribute and letting the engine relay out).

## 4. Put it on a phone

The desktop app and the device app share the same engine; the device apps live
in `android/` and `ios/` and load an HTML asset you edit.

```sh
# Android (device in "Transfer files" USB mode)
tina4pascal deploy                 # .so + APK + install + launch
tina4pascal screenshot shot.png    # see it

# iOS (device unlocked; Xcode signing set once)
tina4pascal ios                    # engine + xcodebuild + install + launch
tina4pascal screenshot shot.png ios
```

Swap `android/app/src/main/assets/controls.html` (or the iOS
`ios/app/controls.html`) for your page, register your actions in the shell
host, and redeploy.

## 5. What you can lean on

- **Services** — `CachePut/Get` (TTL cache) and `StoreSet/Get` (persistent
  localStore), both dependency-free. HTTP/WebSocket are on the roadmap.
- **Verify like the engine does** — `tina4pascal snapshot page.html out.png`
  renders headlessly; `tina4pascal compliance` diffs against Chrome.
- **Tiny output** — ~613 KB Android, ~1.5 MB iOS, whole engine included.

Next: skim the [cheatsheet](CHEATSHEET.md) for the full tag/CSS surface and the
action + services APIs.
