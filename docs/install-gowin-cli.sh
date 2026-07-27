#!/usr/bin/env bash
# One-time setup: makes Gowin's gw_sh callable as a plain `gw_sh` command,
# from any shell, script, or Makefile, without env-var setup each time.
# Idempotent: safe to re-run.
#
# Prerequisite: Gowin IDE must already be installed manually from
# https://www.gowinsemi.com/en/support/download_eda/ (requires a free
# account; not distributable/automatable due to their EULA/click-through).
set -euo pipefail

GOWIN_APP="/Applications/GowinIDE.app"
GOWIN_IDE="$GOWIN_APP/Contents/Resources/Gowin_EDA/IDE"
WRAPPER_DIR="$HOME/.local/bin"
WRAPPER="$WRAPPER_DIR/gw_sh"

if [ ! -d "$GOWIN_APP" ]; then
  echo "Gowin IDE not found at $GOWIN_APP." >&2
  echo "Install it first: https://www.gowinsemi.com/en/support/download_eda/" >&2
  exit 1
fi

mkdir -p "$WRAPPER_DIR"

cat > "$WRAPPER" <<'WRAP'
#!/bin/zsh
# See docs/SETUP.md for why this wrapper exists (macOS SIP strips DYLD_*
# env vars set via a parent shell/Makefile `export`; setting them fresh
# here, right before exec'ing the real binary, always survives).
GOWIN_IDE="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE"
export DYLD_LIBRARY_PATH="$GOWIN_IDE/lib"
export DYLD_FRAMEWORK_PATH="$GOWIN_IDE/lib"
exec "$GOWIN_IDE/bin/gw_sh" "$@"
WRAP
chmod +x "$WRAPPER"
echo "Installed wrapper: $WRAPPER"

RC="$HOME/.zshrc"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qF "$PATH_LINE" "$RC" 2>/dev/null; then
  echo "$PATH_LINE" >> "$RC"
  echo "Added $WRAPPER_DIR to PATH in $RC"
else
  echo "$WRAPPER_DIR already on PATH in $RC"
fi

if ! command -v openFPGALoader >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing openFPGALoader via Homebrew..."
    brew install openfpgaloader
  else
    echo "openFPGALoader not found and Homebrew not available; install manually: https://trabucayre.github.io/openFPGALoader/" >&2
  fi
else
  echo "openFPGALoader already installed: $(command -v openFPGALoader)"
fi

echo
echo "Done. Open a new terminal (or run 'source ~/.zshrc') then verify with:"
echo "  gw_sh   # should print the Tcl console banner, Ctrl-D to exit"
echo "  openFPGALoader --scan-usb"
