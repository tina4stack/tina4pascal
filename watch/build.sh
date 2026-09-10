#!/bin/sh
# Build the Tina4 watchOS engine as a static library (libtina4watch.a).
#
# watchOS has no UIKit/Core Text canvas, so the engine renders HTML with the
# pure-Pascal software rasterizer (Tina4RasterCanvas) and hands the RGBA buffer
# to the WatchKit host. This compiles tina4watch.pas (+ the shared engine units)
# for the watchOS Simulator with the PATCHED FPC that has the aarch64-watchossim
# target (docs/fpc-watchos-patch.md), then archives every object FPC would link
# into one static lib the Swift app links against.
#
# Requires the patched toolchain (compiler + watchossim RTL). Install it to
# ~/fpc-watchos (default) or point TINA4_WATCHOS_FPC at your own prefix; build
# it from docs/fpc-watchossim.diff if you don't have it.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ENG="${TINA4_WATCH_ENG_DIR:-$HERE}"        # dir holding tina4watch.pas, app_units.inc, app/
SRC="${TINA4_SRC:-$HERE/../src}"           # shared engine units
APP_UNIT_DIRS="${TINA4_APP_UNIT_DIRS:-}"   # extra -Fu dirs for a project's own units
WORK="$ENG/build"
OUT="$ENG/app/libtina4watch.a"

FPCW="${TINA4_WATCHOS_FPC:-$HOME/fpc-watchos}"
PPC="$FPCW/bin/ppca64"
RTL="$FPCW/units/aarch64-watchossim"

[ -x "$PPC" ] || { echo "patched watchOS FPC not found at $PPC"; echo "  install to ~/fpc-watchos, or set TINA4_WATCHOS_FPC (see docs/fpc-watchos-patch.md)"; exit 2; }
[ -f "$RTL/system.ppu" ] || { echo "watchossim RTL missing at $RTL (need system.ppu …)"; exit 2; }

SDK="$(xcrun --sdk watchsimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || { echo "watchsimulator SDK not found (install Xcode watchOS platform)"; exit 2; }

mkdir -p "$ENG/app"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "compiling Pascal for arm64 watchOS Simulator…"
# -Cn: compile only, skip FPC's own link (the app links); it still writes the
# linkfiles*.res listing every object we must archive. -Fu the watchossim RTL
# explicitly (fpcmake can't generate a Makefile for the unknown target).
# shellcheck disable=SC2086
"$PPC" -Mdelphi -Twatchossim -Paarch64 -O2 -Cn -XR"$SDK" \
    -Fu"$RTL" -FE"$WORK" -FU"$WORK" -Fu"$SRC" $APP_UNIT_DIRS "$ENG/tina4watch.pas" \
    2>&1 | grep -Ei "error|fatal" && { echo "COMPILE FAILED"; exit 1; } || true

RES="$(ls "$WORK"/linkfiles*.res 2>/dev/null | head -1)"
[ -n "$RES" ] || { echo "no linkfiles res produced"; exit 1; }

# collect every .o the program would link (ours + RTL)
OBJS="$(grep -E '\.o$' "$RES" | tr -d '\r')"
COUNT="$(printf '%s\n' "$OBJS" | wc -l | tr -d ' ')"
echo "archiving $COUNT objects → libtina4watch.a"

# shellcheck disable=SC2086
libtool -static -o "$OUT" $OBJS 2>/dev/null

echo "  ok → $OUT ($(wc -c < "$OUT") bytes)"
