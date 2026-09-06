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

## Status — all platforms wired

| Platform | Copy `fonts/` | Register + load | Verified |
|---|---|---|---|
| Linux (FreeType) | ✅ beside exe | ✅ file-based, `fonts/` first | ✅ serif override |
| Windows (GDI) | ✅ beside exe | ✅ `AddFontResourceExW(FR_PRIVATE)` + `FaceFor` | ✅ DejaVu vs Segoe |
| macOS (CoreText) | ✅ `build_prog` → `build/macos/fonts/` | ✅ `EnsureBundledCocoaFonts` + `FontFor` | ✅ **DejaVu vs San Francisco** |
| iOS (CoreText) | ✅ staged under `assets/fonts/` | ✅ `EnsureBundledIOSFonts` + `IOSBaseFontName` | ⬜ compiles; needs a device build |
| Android (Paint) | ✅ APK `assets/fonts/` | ✅ `EnsureBundledFonts` + `TypefaceFor` | ✅ **DejaVu vs Noto/Roboto** (emulator) |

Each shell scans its `fonts/*.ttf` once (lazily, on first font resolution),
registers each with the OS text engine process-wide, records which DejaVu
generics shipped, and backs the CSS generics with them in the font selector —
falling back to the system face when a generic isn't bundled (so bundling only
Sans+Serif leaves `monospace` on the system mono, verified on macOS).

## How each platform does it

- **macOS** (`src/Tina4ShellCocoa.pas`): `EnsureBundledCocoaFonts` scans
  `<exe dir>/fonts` and `../Resources/fonts` (inside a `.app`), registers via
  `CTFontManagerRegisterFontsForURL(kCTFontManagerScopeProcess)`; `FontFor`
  maps the generics to `DejaVu Sans/Serif/Sans Mono`.
- **iOS** (`src/Tina4ShellIOS.pas`): the URL/descriptor API is macOS-only, so
  `EnsureBundledIOSFonts` registers each file via the CoreGraphics path
  (`CGFontCreateWithDataProvider` → `CTFontManagerRegisterGraphicsFont`) and maps
  generics by the font's **PostScript name**. Fonts ride the already-bundled
  `assets/` folder reference (packager copies `fonts/` → `assets/fonts/`); the
  scan checks both `<app>/fonts` and `<app>/assets/fonts`.
- **Android** (`src/Tina4ShellAndroid.pas`): the packager copies `fonts/` into
  the APK at `assets/fonts/`; MainActivity extracts assets to `filesDir/assets`,
  so `EnsureBundledFonts` loads each with `Typeface.createFromFile` (JNI) and
  `TypefaceFor` returns the bundled typeface for a generic, else the system one.
- **Linux / Windows**: the original references — `Tina4ShellLinux.pas`
  (`FtFontFile`/`FontDirs`) and `Tina4ShellWin.pas`
  (`EnsureBundledWinFonts` + `FaceFor`).

To finish iOS/Android verification: build for the target
(`tina4pascal build ios` / `build android`), drop a `DejaVuSerif.ttf` in the
project `fonts/`, run on a device/emulator, and confirm serif renders DejaVu
(loud diff vs the system serif) — the same check that passed on macOS.

## Notes

- The generic→DejaVu mapping is by the **DejaVu filename convention**; a bundled
  file must actually *be* that family (GDI/CoreText resolve by the font's internal
  family name, not the filename). Arbitrary fonts still work when the CSS names
  them explicitly.
- A future hardening step: read each registered font's real family name (Windows:
  GDI+ `PrivateFontCollection`; macOS/iOS: already done in `RegisterFont`) and map
  generics to whatever shipped, instead of assuming DejaVu names.
