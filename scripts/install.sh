#!/bin/sh
# Tina4Pascal one-line bootstrap (macOS / Linux).
#
#   curl -fsSL https://raw.githubusercontent.com/tina4stack/tina4pascal/main/scripts/install.sh | sh
#
# Fetches the framework, symlinks the CLI onto your PATH, and runs doctor. FPC
# and the cross toolchains are fetched on first `tina4pascal init` / `setup`.
# Override the location with $TINA4_HOME.
set -eu

REPO="https://github.com/tina4stack/tina4pascal"
DIR="${TINA4_HOME:-$HOME/.tina4pascal}"

echo "Installing Tina4Pascal -> $DIR"

# 1. get the source (git if present, else the branch tarball)
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only
elif command -v git >/dev/null 2>&1; then
  git clone --depth 1 "$REPO.git" "$DIR"
else
  tmp="$(mktemp -d)"
  curl -fsSL "$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$tmp"
  rm -rf "$DIR"; mkdir -p "$(dirname "$DIR")"; mv "$tmp/tina4pascal-main" "$DIR"
  rm -rf "$tmp"
fi

chmod +x "$DIR/tools/tina4pascal" 2>/dev/null || true

# 2. put `tina4pascal` on PATH (symlink into a bin dir that already is, if we can)
linked=""
for b in "$HOME/.local/bin" /usr/local/bin; do
  if [ -d "$b" ] && [ -w "$b" ]; then
    ln -sf "$DIR/tools/tina4pascal" "$b/tina4pascal"; linked="$b/tina4pascal"; break
  fi
done
if [ -z "$linked" ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DIR/tools/tina4pascal" "$HOME/.local/bin/tina4pascal"; linked="$HOME/.local/bin/tina4pascal"
  echo "Add \$HOME/.local/bin to your PATH to use 'tina4pascal' directly."
fi

# 3. report the toolchain
"$DIR/tools/tina4pascal" doctor || true

echo ""
echo "Tina4Pascal installed ($linked). Get started:"
echo "  tina4pascal init hello    # scaffold + build + run (fetches FPC on first run)"
