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
SRC="${TINA4_SRC:-$HERE/../src}"            # shared engine units
APP_UNIT_DIRS="${TINA4_APP_UNIT_DIRS:-}"    # extra -Fu dirs for a project's own units

# Two rendering paths, both into App/libtina4iossim.a (the app links one lib):
#   default = NATIVE  — Tina4ShellIOS (Core Graphics / Core Text), device-identical.
#                       Needs univint built for iphonesim (docs/fpc-iphonesim.md).
#   --raster / TINA4_SIM_RASTER=1 — the pure-Pascal raster canvas (no univint),
#                       same rough fonts as the watch; the no-framework fallback.
MODE="native"
[ "${1:-}" = "--raster" ] && MODE="raster"
[ "${TINA4_SIM_RASTER:-0}" = "1" ] && MODE="raster"
if [ "$MODE" = "raster" ]; then
  ENG="${TINA4_IOSSIM_ENG_DIR:-$HERE/sim}"        # tina4iossim.pas
  ENTRY="$ENG/tina4iossim.pas"
else
  ENG="${TINA4_IOSSIM_ENG_DIR:-$HERE/sim/native}" # tina4iossimnative.pas
  ENTRY="$ENG/tina4iossimnative.pas"
fi
WORK="$ENG/build"
OUT="$HERE/sim/App/libtina4iossim.a"

FPCW="${TINA4_SIM_FPC:-$HOME/fpc-watchos}"
PPC="$FPCW/bin/ppca64"
RTL="$FPCW/units/aarch64-iphonesim"

[ -x "$PPC" ] || { echo "patched FPC not found at $PPC"; echo "  install to ~/fpc-watchos, or set TINA4_SIM_FPC (see docs/fpc-iphonesim.md)"; exit 2; }
[ -f "$RTL/system.ppu" ] || { echo "iphonesim RTL missing at $RTL (need system.ppu …); see docs/fpc-iphonesim.md"; exit 2; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || { echo "iPhoneSimulator SDK not found (install Xcode iOS platform)"; exit 2; }

mkdir -p "$HERE/sim/App"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "compiling Pascal for arm64 iOS Simulator ($MODE canvas)…"
# shellcheck disable=SC2086
"$PPC" -Mdelphi -Tiphonesim -Paarch64 -O2 -Cn -XR"$SDK" \
    -Fu"$RTL" -FE"$WORK" -FU"$WORK" -Fu"$SRC" $APP_UNIT_DIRS "$ENTRY" \
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
