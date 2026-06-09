#!/usr/bin/env bash
# devmode.sh — Build and deploy Muxlet to a Mudlet dev profile.
#
# Run this after every `muddle` build, or combine them:
#   muddle && ./devmode.sh
#
# Works in WSL, native Linux, and macOS.
# The first run creates the profile directory and prints first-time setup steps.
# Subsequent runs copy the package and update the stamp file that the in-package
# auto-reload timer watches — Mudlet reinstalls within ~30 seconds.
# Type "mux reload" in Mudlet for an immediate reload.
#
# Usage:
#   ./devmode.sh [profile-name]   (default: mux-dev)

set -euo pipefail

PROFILE="${1:-mux-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_PACKAGE="$SCRIPT_DIR/build/Muxlet.mpackage"

# ── Find Mudlet config directory ─────────────────────────────────────────────

find_mudlet_config() {
    # Native Linux / XDG
    local xdg_path="${XDG_CONFIG_HOME:-$HOME/.config}/mudlet"
    [ -d "$xdg_path/profiles" ] && { echo "$xdg_path"; return; }

    # macOS
    local mac_path="$HOME/Library/Application Support/Mudlet"
    [ -d "$mac_path/profiles" ] && { echo "$mac_path"; return; }

    # WSL: Windows drives mounted at /mnt/c — no wslpath or env vars needed.
    # Checks both the non-standard %USERPROFILE%\.config\mudlet layout and
    # the standard %APPDATA%\Mudlet layout across all user directories.
    for user_dir in /mnt/c/Users/*/; do
        [ -d "$user_dir" ] || continue
        [ -d "${user_dir}.config/mudlet/profiles" ] && { echo "${user_dir}.config/mudlet"; return; }
        [ -d "${user_dir}AppData/Roaming/Mudlet/profiles" ] && { echo "${user_dir}AppData/Roaming/Mudlet"; return; }
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo "=== Muxlet devmode deploy ==="
echo ""

MUDLET_CONFIG="$(find_mudlet_config || true)"

if [ -z "$MUDLET_CONFIG" ]; then
    echo "ERROR: Could not find Mudlet config directory." >&2
    echo "Launch Mudlet at least once, then re-run this script." >&2
    exit 1
fi

echo "Mudlet config : $MUDLET_CONFIG"

PROFILE_DIR="$MUDLET_CONFIG/profiles/$PROFILE"
FIRST_TIME=0

if [ ! -d "$PROFILE_DIR" ]; then
    mkdir -p "$PROFILE_DIR"
    echo "Created profile: $PROFILE"
    FIRST_TIME=1
else
    echo "Profile       : $PROFILE"
fi

if [ ! -f "$SRC_PACKAGE" ]; then
    echo "" >&2
    echo "ERROR: build/Muxlet.mpackage not found." >&2
    echo "Run muddle first, then re-run this script." >&2
    exit 1
fi

DEST_PACKAGE="$PROFILE_DIR/Muxlet.mpackage"
cp "$SRC_PACKAGE" "$DEST_PACKAGE"
echo "Deployed      : $DEST_PACKAGE"

STAMP_PATH="$PROFILE_DIR/Muxlet-rebuild.stamp"
date +%s > "$STAMP_PATH"
echo "Stamp written : $STAMP_PATH"

echo ""

if [ "$FIRST_TIME" -eq 1 ]; then
    echo "FIRST-TIME SETUP:"
    echo "  1. Open Mudlet"
    echo "  2. Select profile: '$PROFILE'"
    echo "     (no game connection needed — Muxlet is game-agnostic)"
    echo "  3. Toolbox -> Package Manager -> Install from file:"
    echo "     $DEST_PACKAGE"
    echo ""
    echo "After this one-time install, the auto-reload handles everything."
    echo ""
fi

echo "ONGOING WORKFLOW:"
echo "  muddle && ./devmode.sh"
echo "  Mudlet auto-reloads within ~30 seconds."
echo "  Or type in Mudlet: mux reload   for an immediate reload."
echo ""
