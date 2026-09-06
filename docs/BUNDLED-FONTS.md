# Bundled fonts

Ship an app's own fonts so it renders **identically on every platform** — even
minimal containers with no system fonts.

## The contract (all platforms)

- A project has a **`fonts/` folder**; `tina4pascal build` copies it next to the
  executable (desktop) / into the app bundle or APK assets (mobile).
- At startup the shell **registers** every `fonts/*.ttf` with the OS text engine.
- Font resolution is **bundled-first**: if a bundled DejaVu family is present it
  backs the generic CSS families, otherwise the platform's system default is used:

  | CSS family | bundled file | system fallback |
  |---|---|---|
  | `sans-serif` / `system-ui` | `DejaVuSans*.ttf` → "DejaVu Sans" | Segoe UI / San Francisco / DejaVu |
  | `serif` | `DejaVuSerif*.ttf` → "DejaVu Serif" | Times / Georgia |
  | `monospace` | `DejaVuSansMono*.ttf` → "DejaVu Sans Mono" | Consolas / Menlo |

  An **explicit** `font-family: "Foo"` resolves to any bundled `Foo` because the
  file was registered by family name.
- Empty `fonts/` → everything uses system fonts (today's behaviour).

## Status

| Platform | Scaffold + copy | Register + load | Verified |
|---|---|---|---|
| Linux (FreeType) | ✅ | ✅ (file-based, `fonts/` beside exe first) | ✅ serif override |
| Windows (GDI) | ✅ | ✅ `AddFontResourceExW(FR_PRIVATE)` + family map | ✅ DejaVu vs Segoe |
| macOS (CoreText) | ✅ copy | ⬜ **TODO** (see below) | — |
| iOS (CoreText) | ✅ copy | ⬜ **TODO** | — |
| Android (Paint) | ✅ copy | ⬜ **TODO** | — |

The reference implementations are `Tina4ShellLinux.pas` (`FtFontFile` +
`FontDirs`) and `Tina4ShellWin.pas` (`EnsureBundledWinFonts` + `FaceFor`).

## macOS — how to finish (`src/Tina4ShellCocoa.pas`)

The shell **already** has `RegisterFont(Family, Src)` using
`CTFontManagerRegisterFontsForURL` and reads back the real family name — reuse it.

1. Add `EnsureBundledFonts` (call once, e.g. at the top of `FontFor`):
   - font dir = `<exe dir>/fonts` — the binary is at
     `Contents/MacOS/<exe>` in a `.app`, so also check `../Resources/fonts`;
     `ExtractFilePath(ParamStr(0))` gives the MacOS dir.
   - for each `*.ttf`: `CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, nil)`
     (already wrapped in `RegisterFont`), and note which DejaVu families shipped.
2. In `FontFor`, before falling back to the system face, map the generics to the
   bundled DejaVu family names (mirror `Tina4ShellWin.FaceFor`), then
   `NSFont.fontWithName_size(NSStr('DejaVu Sans'), sz)`.
3. Verify: `bash tools/tina4pascal build macos`, drop `DejaVuSans.ttf` in the
   project `fonts/`, `--snapshot` the demo, confirm it renders DejaVu (compare to
   a no-`fonts/` run in San Francisco). Same serif trick as Linux for a loud diff.

## iOS — how to finish (`src/Tina4ShellIOS.pas`)

Same CoreText API as macOS. Fonts live in the app bundle (the packager already
copies `fonts/` into the `.app`); resolve the dir via `NSBundle.mainBundle` /
`ParamStr(0)`'s bundle. Register with `CTFontManagerRegisterFontsForURL` and map
generics in the font selector. (You *can* also list them in Info.plist under
`UIAppFonts`, but process-scope registration avoids the plist edit.)

## Android — how to finish (`src/Tina4ShellAndroid.pas` + Java)

Text is drawn through the Android `Canvas`/`Paint` (see `Tina4View.java`,
`nativePaint`). Fonts:

1. Packager: copy the project `fonts/` into the APK at `assets/fonts/` (extend
   the `assets` copy step in `android/build.sh` / the POSIX `build_project_android`).
2. Load: `Typeface.createFromAsset(assetManager, "fonts/DejaVuSans.ttf")` (Java),
   cache per family/style, and `paint.setTypeface(tf)` in the paint path. Bridge
   the chosen family name from the Pascal `FontFor` decision over JNI, or make the
   Java side own the same generic→bundled mapping.
3. Verify on an emulator: `tina4pascal build android`, install, screenshot.

## Notes

- The generic→DejaVu mapping is by the **DejaVu filename convention**; a bundled
  file must actually *be* that family (GDI/CoreText resolve by the font's internal
  family name, not the filename). Arbitrary fonts still work when the CSS names
  them explicitly.
- A future hardening step: read each registered font's real family name (Windows:
  GDI+ `PrivateFontCollection`; macOS/iOS: already done in `RegisterFont`) and map
  generics to whatever shipped, instead of assuming DejaVu names.
