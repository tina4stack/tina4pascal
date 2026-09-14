#!/bin/sh
# Build the Tina4 engine as a static library for the iOS *Simulator*
# (libtina4iossim.a, arm64).
#
# FPC 3.2.2 ships no simulator target, so the normal ios/build.sh (-Tios, the
# native UIKit/Core Graphics shell) can't target the Simulator. The PATCHED
# trunk compiler at ~/fpc-watchos has the upstream `iphonesim` target (arm64
# LP64) and an aarch64-iphonesim RTL; this compiles the raster engine
# (ios/sim/tina4iossim.pas — the pure-Pascal software rasterizer, same path the
# Apple Watch uses) for it and archives every object into one static lib the
# Simulator app links against.
#
# -Cn: compile only, skip FPC's own link — the app links, and FPC's iphonesim
# linker step emits the old -ios_simulator_version_min flag that Xcode 26's ld
# rejects (docs/OUTSTANDING.md F). Xcode does the final link with the right
# -platform_version, so the static-lib path never trips that upstream bug.
#
# Requires the patched toolchain + iphonesim RTL (install to ~/fpc-watchos, or
# set TINA4_SIM_FPC; build the RTL per docs/fpc-iphonesim.md).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ENG="${TINA4_IOSSIM_ENG_DIR:-$HERE/sim}"    # dir holding tina4iossim.pas, app_units.inc
SRC="${TINA4_SRC:-$HERE/../src}"            # shared engine units
APP_UNIT_DIRS="${TINA4_APP_UNIT_DIRS:-}"    # extra -Fu dirs for a project's own units
WORK="$ENG/build"
OUT="$ENG/App/libtina4iossim.a"

FPCW="${TINA4_SIM_FPC:-$HOME/fpc-watchos}"
PPC="$FPCW/bin/ppca64"
RTL="$FPCW/units/aarch64-iphonesim"

[ -x "$PPC" ] || { echo "patched FPC not found at $PPC"; echo "  install to ~/fpc-watchos, or set TINA4_SIM_FPC (see docs/fpc-iphonesim.md)"; exit 2; }
[ -f "$RTL/system.ppu" ] || { echo "iphonesim RTL missing at $RTL (need system.ppu …); see docs/fpc-iphonesim.md"; exit 2; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || { echo "iPhoneSimulator SDK not found (install Xcode iOS platform)"; exit 2; }

mkdir -p "$ENG/App"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "compiling Pascal for arm64 iOS Simulator…"
# shellcheck disable=SC2086
"$PPC" -Mdelphi -Tiphonesim -Paarch64 -O2 -Cn -XR"$SDK" \
    -Fu"$RTL" -FE"$WORK" -FU"$WORK" -Fu"$SRC" $APP_UNIT_DIRS "$ENG/tina4iossim.pas" \
    2>&1 | grep -Ei "error|fatal" && { echo "COMPILE FAILED"; exit 1; } || true

RES="$(ls "$WORK"/linkfiles*.res 2>/dev/null | head -1)"
[ -n "$RES" ] || { echo "no linkfiles res produced"; exit 1; }

# collect every .o the program would link (ours + RTL)
OBJS="$(grep -E '\.o$' "$RES" | tr -d '\r')"
COUNT="$(printf '%s\n' "$OBJS" | wc -l | tr -d ' ')"
echo "archiving $COUNT objects → libtina4iossim.a"

# shellcheck disable=SC2086
libtool -static -o "$OUT" $OBJS 2>/dev/null

echo "  ok → $OUT ($(wc -c < "$OUT") bytes)"
