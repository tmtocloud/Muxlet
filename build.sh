#!/usr/bin/env bash
# build.sh — Build the Muxlet package.
#
# Reads version from mfile (source of truth), patches mfile temporarily,
# runs muddle, then restores mfile so the committed value stays clean.
#
# The CI workflow controls the GitHub release type:
#   Prerelease (push to main):        tag_name = "1.2.3"   (bare, no "v" prefix)
#   Release (annotated v* tag):       tag_name = "v1.2.3"
#
# Locally:
#   Dev build (no matching v* tag):   version = "1.2.3-a3f91cd"
#   Release build (exact v* tag):     version = "1.2.3"
#
# Works in WSL, native Linux, and macOS.
#
# Usage:
#   ./build.sh [--profile PROFILE] [--mudlet-config PATH]
#
# Examples:
#   ./build.sh
#   ./build.sh --profile mux-dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MFILE="$SCRIPT_DIR/mfile"
SRC_PACKAGE="$SCRIPT_DIR/build/Muxlet.mpackage"

PROFILE=""
MUDLET_CONFIG=""

# ── Parse arguments ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)       PROFILE="$2";       shift 2 ;;
        --mudlet-config) MUDLET_CONFIG="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

echo ""
echo "=== Muxlet build ==="

# ── Read version from mfile ───────────────────────────────────────────────────

BASE_VERSION="$(jq -r '.version' "$MFILE")"
if [[ -z "$BASE_VERSION" || "$BASE_VERSION" == "null" ]]; then
    echo "ERROR: mfile is missing 'version' field." >&2
    exit 1
fi

EXACT_TAG="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$EXACT_TAG" == "v$BASE_VERSION" ]]; then
    VERSION="$BASE_VERSION"
else
    SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "local")"
    VERSION="$BASE_VERSION-$SHORT_SHA"
fi

echo "Version       : $VERSION"

# ── Patch mfile temporarily ───────────────────────────────────────────────────

ORIGINAL_MFILE="$(cat "$MFILE")"
PATCHED_MFILE="$(echo "$ORIGINAL_MFILE" | sed 's/"version":[[:space:]]*"[^"]*"/"version": "'"$VERSION"'"/')"
echo "$PATCHED_MFILE" > "$MFILE"
echo "mfile         : version set to $VERSION"

# ── Run muddle ────────────────────────────────────────────────────────────────

restore_mfile() {
    echo "$ORIGINAL_MFILE" > "$MFILE"
    echo "mfile         : restored"
}
trap restore_mfile EXIT

muddle
echo "Output        : $SRC_PACKAGE"

# Restore immediately (trap also fires on exit, but restore early for clarity)
restore_mfile
trap - EXIT

# ── Deploy to profile (optional) ─────────────────────────────────────────────

if [ -z "$PROFILE" ]; then
    echo ""
    exit 0
fi

echo ""
echo "=== Deploying to profile: $PROFILE ==="

# Find Mudlet config directory
find_mudlet_config() {
    local xdg_path="${XDG_CONFIG_HOME:-$HOME/.config}/mudlet"
    [ -d "$xdg_path/profiles" ] && { echo "$xdg_path"; return; }

    local mac_path="$HOME/Library/Application Support/Mudlet"
    [ -d "$mac_path/profiles" ] && { echo "$mac_path"; return; }

    for user_dir in /mnt/c/Users/*/; do
        [ -d "$user_dir" ] || continue
        [ -d "${user_dir}.config/mudlet/profiles" ] && { echo "${user_dir}.config/mudlet"; return; }
        [ -d "${user_dir}AppData/Roaming/Mudlet/profiles" ] && { echo "${user_dir}AppData/Roaming/Mudlet"; return; }
    done
}

if [ -z "$MUDLET_CONFIG" ]; then
    MUDLET_CONFIG="$(find_mudlet_config || true)"
fi

if [ -z "$MUDLET_CONFIG" ]; then
    echo "ERROR: Could not find Mudlet config directory." >&2
    echo "Launch Mudlet at least once, or pass --mudlet-config explicitly." >&2
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
    echo "ERROR: build/Muxlet.mpackage not found after build step." >&2
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

echo "WORKFLOW:"
echo "  ./build.sh --profile $PROFILE"
echo "  Mudlet auto-reloads within ~30 seconds."
echo "  Or type in Mudlet: mux reload   for an immediate reload."
echo ""
