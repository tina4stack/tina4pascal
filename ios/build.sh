#!/bin/sh
# Build the Tina4 iOS engine as a static library (libtina4ios.a) for Xcode.
#
# FPC compiles the whole Pascal side (shared Tina4Interact engine + the Core
# Graphics / Core Text canvas in Tina4ShellIOS) for arm64 iOS. We then bundle
# every object FPC would have linked — ours plus the FPC RTL and univint
# framework bindings — into one static archive that the Obj-C app links against.
#
# The app (ios/app) supplies main.m / the UIView host / Info.plist and the
# Apple frameworks; open it in Xcode, set your signing team, and Run.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# Env overrides let the CLI build a per-project STAGED host (its own tina4ios.pas
# + app_units.inc + app/ output dir) while still pointing at the repo engine
# sources. Unset ⇒ the reference in-repo build, byte-for-byte as before.
ENG="${TINA4_IOS_ENG_DIR:-$HERE}"          # dir holding tina4ios.pas, app_units.inc, app/
SRC="${TINA4_SRC:-$HERE/../src}"           # shared engine units
THREED="${TINA4_3D:-$HERE/../3d}"
SHEEP="${TINA4_SHEEP:-$HERE/../examples/sheep3d}"
APP_UNIT_DIRS="${TINA4_APP_UNIT_DIRS:-}"   # extra -Fu dirs for a project's own units
WORK="$ENG/build"
OUT="$ENG/app/libtina4ios.a"

export PPC_CONFIG_PATH="${PPC_CONFIG_PATH:-$HOME/fpc/etc}"
export PATH="$HOME/fpc/bin:$PATH"

rm -rf "$WORK"; mkdir -p "$WORK"

echo "compiling Pascal for arm64 iOS…"
# -Cn: compile only, skip FPC's own link (the app links); it still writes the
# linkfiles*.res listing every object we must archive.
# shellcheck disable=SC2086
fpc -Mdelphi -Tios -Paarch64 -O2 -Cn \
    -FE"$WORK" -FU"$WORK" -Fu"$SRC" -Fu"$THREED" -Fu"$SHEEP" $APP_UNIT_DIRS "$ENG/tina4ios.pas" \
    2>&1 | grep -Ei "error|fatal" && { echo "COMPILE FAILED"; exit 1; } || true

RES="$(ls "$WORK"/linkfiles*.res 2>/dev/null | head -1)"
[ -n "$RES" ] || { echo "no linkfiles res produced"; exit 1; }

# collect every .o the program would link (ours + RTL + univint)
OBJS="$(grep -E '\.o$' "$RES" | tr -d '\r')"
COUNT="$(printf '%s\n' "$OBJS" | wc -l | tr -d ' ')"
echo "archiving $COUNT objects → libtina4ios.a"

# shellcheck disable=SC2086
libtool -static -o "$OUT" $OBJS 2>/dev/null

echo "  ok → $OUT ($(wc -c < "$OUT") bytes)"
echo
echo "Frameworks the app must link (from the FPC link script):"
grep -A1 -E '^-framework' "$WORK"/link*.res 2>/dev/null | grep -vE '^-framework|^--' | sort -u | sed 's/^/  -framework /'
