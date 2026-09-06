# Tooling, portability & store distribution

How a Tina4Pascal project stays **zip-portable / git-committable and builds on
anyone's computer**, where the build tools and signing assets live, and what it
takes to ship to the **Play Store**, **App Store** and **TestFlight**.

Status legend: ✅ done · �build in progress · ⬜ planned.

## Two roots: machine cache vs. portable project

**1. Machine toolchain cache — `~/.tina4/` (downloaded once, shared by every
project, never committed).** Override the root with `TINA4_HOME`.

```
~/.tina4/
  toolchains/
    fpc/<ver>/            # FPC + cross RTLs
    android/sdk/          # cmdline-tools, build-tools/<v>, platforms/<v>, platform-tools
    android/ndk/<v>/
    bin/                  # pymobiledevice3, xcodegen, …
  keystores/              # RELEASE keystores = secrets, per bundleId, never in a repo
    com.tina4.myapp.jks
  toolchain.json          # resolved paths + installed versions on THIS machine ⬜
```

The CLI resolves every tool **env → `~/.tina4` → common system locations** ✅, so
this Mac (FPC at `~/fpc`, SDK under `/opt/homebrew`) keeps working while a clone
resolves tools wherever they are. `tina4pascal setup <fpc|android|ios>` installs
into `~/.tina4` at the versions the project pins 🏗.

**2. Project folder — portable, commit/zip it and it runs anywhere.**

```
myapp/
  tina4.json             # pins tool VERSIONS + signing CONFIG (not secrets)   ✅
  app.pas                # entry point — configurable via tina4.json "main"    ✅
  src/{routes,orm,services,templates}/                                          ✅
  assets/  migrations/                                                          ✅
  signing/
    debug.keystore       # committable shared debug key (installable debug only) ✅
    README.md            # how to point at a release key                         ✅
  platforms/             # generated, committable, regenerable host scaffolds    ⬜
    android/  ios/        #   (`tina4pascal sync` regenerates from tina4.json)
  build/                 # gitignored outputs                                    ✅
  .tina4/local.json      # gitignored per-machine overrides / release creds      ⬜
  .gitignore             # ignores build, *.keystore except signing/debug        ✅
```

### The portability contract
`git clone && tina4pascal setup && tina4pascal build <target>` works anywhere:
**the project pins tool versions, the CLI resolves/downloads the paths.** Debug
signing travels with the repo (deterministic debug builds); release signing lives
in `~/.tina4/keystores` or env and is only *referenced* by `tina4.json`.

## Entry point ✅
`tina4.json → "main"` selects the compiled `.pas` (default `app.pas` at the
project root). Desktop targets compile it to an executable; mobile targets build a
host package (below). `app.pas` and `tina4.json` carry inline comments explaining
what to change.

## The mobile UI: one render path everywhere ✅→🏗
`<host> --dump-html <file>` renders the project's Twig entry template to static
HTML ✅. The Android/iOS host bundles that as its asset, so a phone shows the exact
same UI the desktop renders — no second templating path.

## Android → APK / AAB / Play 🏗
`tina4pascal build android` packages a scaffolded project gradle-free (reusing the
reference app's Java + JNI + `aapt2/d8/apksigner`):
- **applicationId** = `bundleId` via `aapt2 link --rename-manifest-package <id>
  --custom-package com.tina4.pascal` (keeps the shared Java/R package, sets the
  store id); activity referenced by FQCN.  ✅ *(verified on the emulator: a
  scaffolded project installs as its own `com.tina4.<name>` and renders its UI)*
- **icons** from `assets/icon.png` (all mipmap densities).  ✅
- **min/target SDK** from `tina4.json`.  ✅
- **debug build** signs with `signing/debug.keystore` (falls back to the repo key). ✅
- **UI** = `--dump-html` of the entry template, bundled as the `showcase.html`
  asset.  ✅  · project `assets/` are bundled into the APK ✅, but a relative
  `<img src="assets/…">` doesn't resolve on-device yet — needs the Android shell
  to load from APK assets (extract to filesDir on first run, or an `asset://`
  scheme in the image loader).  ⬜ *(follow-up)*
- **release**: `tina4pascal release android` → a **signed AAB** (`bundletool`) —
  Play requires an `.aab`, not an `.apk` — plus a signed universal APK for
  sideload testing. Signs from `TINA4_KEYSTORE`/`TINA4_KEY_ALIAS`/`TINA4_KS_PASS`. ⬜
- **upload**: `tina4pascal publish android` via the Play Developer API (service
  account JSON in `~/.tina4/`, never committed) → internal/closed/production track. ⬜

## iOS → .app / IPA / TestFlight / App Store ⬜
- Generate `platforms/ios/` (xcodeproj via `xcodegen`, or a direct `xcodebuild`
  project) linking the FPC-built static lib + the shared Cocoa/iOS shell.
- **Signing** needs, from the Apple Developer account:
  - an **Apple Team ID** (`tina4.json.ios.team` / `TINA4_IOS_TEAM`),
  - a **signing certificate** (Apple Distribution) in the login keychain,
  - a **provisioning profile** (App Store) matching the bundle id + entitlements.
- `tina4pascal release ios` → `xcodebuild archive` → `-exportArchive` with an
  `exportOptions.plist` → a signed **IPA**.
- **TestFlight / App Store**: `tina4pascal publish ios` uploads the IPA with
  `xcrun altool`/`notarytool` or the App Store Connect API (issuer id + key `.p8`
  in `~/.tina4/`, never committed). TestFlight = upload to App Store Connect and
  enable the beta; App Store = submit the build for review.

## What a user must supply for the stores (checklist)
- **Play**: a Google Play Developer account; a **release keystore** (`tina4pascal
  keygen`, kept in `~/.tina4/keystores`); a Play **service-account JSON** for
  automated upload; store listing (icon, screenshots, privacy policy).
- **App Store / TestFlight**: an Apple Developer Program membership; **Team ID**;
  an **App Store Connect API key** (`.p8` + issuer id + key id); an app record +
  bundle id registered in App Store Connect; a distribution cert + provisioning
  profile (the CLI can create these via the API).

## Secrets rule (applies everywhere)
Committable: `tina4.json`, `app.pas`, `src/`, `assets/`, `signing/debug.keystore`,
generated `platforms/`. **Never committed**: release keystores, `.p8`/service-account
keys, store passwords — they live in `~/.tina4/` or env and are only referenced by
config. `.gitignore` enforces this (`*.keystore`/`*.jks` ignored except the debug key).
