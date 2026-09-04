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
SRC="$HERE/../src"
WORK="$HERE/build"
OUT="$HERE/app/libtina4ios.a"

export PPC_CONFIG_PATH="${PPC_CONFIG_PATH:-$HOME/fpc/etc}"
export PATH="$HOME/fpc/bin:$PATH"

rm -rf "$WORK"; mkdir -p "$WORK"

echo "compiling Pascal for arm64 iOS…"
# -Cn: compile only, skip FPC's own link (the app links); it still writes the
# linkfiles*.res listing every object we must archive.
fpc -Mdelphi -Tios -Paarch64 -O2 -Cn \
    -FE"$WORK" -FU"$WORK" -Fu"$SRC" "$HERE/tina4ios.pas" \
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
