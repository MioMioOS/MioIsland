#!/usr/bin/env bash
# safe-install-app.sh — Replace /Applications/Mio Island.app without nesting.
#
# Usage:
#   ./scripts/safe-install-app.sh /path/to/built/"Mio Island.app" [--launch-verify]
#
# Flags:
#   --launch-verify   After install, open the app and assert the running instance's
#                     bundle path is /Applications/Mio Island.app (not DerivedData).
#                     Exits non-zero if the wrong binary is running.
#
# What this script does (in order):
#   1. Validates the source .app exists and is a real Mio Island bundle.
#   2. Quits any running "Mio Island" process gracefully (SIGTERM → wait → SIGKILL).
#   3. Removes the old /Applications/Mio Island.app (avoids cp -R nesting bug).
#   4. Copies the new bundle into /Applications/.
#   5. Clears Gatekeeper quarantine so the app opens without prompts.
#   6. Verifies the installed CFBundleIdentifier matches the expected value.
#   7. No-nesting assertion (ensures source was not nested inside target).
#   8. [--launch-verify only] Opens the installed app and asserts lsappinfo shows
#      bundle path = /Applications/Mio Island.app.
#
# Background (why this matters):
#   `cp -R source.app /Applications/existing.app` nests source INSIDE destination
#   instead of replacing it. You end up opening the old outer bundle.
#   The fix is: rm -rf first, then cp -R into the PARENT directory.
#
# Incident reference: 2026-05-22 — the old /Applications/Mio Island.app contained
#   the new build nested at /Applications/Mio Island.app/Mio Island.app, so Laurent
#   was running the old version even after the "install". (@운위 caught and un-nested.)

set -euo pipefail

EXPECTED_BUNDLE_ID="com.codeisland.app"
TARGET="/Applications/Mio Island.app"
APP_PROCESS_NAME="Mio Island"

# ── Argument parsing ──────────────────────────────────────────────────────────

SOURCE=""
LAUNCH_VERIFY=false

for arg in "$@"; do
    case "$arg" in
        --launch-verify)
            LAUNCH_VERIFY=true
            ;;
        --*)
            echo "Error: unknown flag: $arg"
            echo "Usage: $0 /path/to/built/\"Mio Island.app\" [--launch-verify]"
            exit 1
            ;;
        *)
            if [[ -z "$SOURCE" ]]; then
                SOURCE="$arg"
            else
                echo "Error: unexpected argument: $arg"
                exit 1
            fi
            ;;
    esac
done

# ── 1. Validate source ────────────────────────────────────────────────────────

if [[ -z "$SOURCE" ]]; then
    echo "Usage: $0 /path/to/built/\"Mio Island.app\" [--launch-verify]"
    exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
    echo "Error: source not found or not a directory: $SOURCE"
    exit 1
fi

# Confirm it's the right bundle by checking CFBundleIdentifier.
SOURCE_BUNDLE_ID=$(defaults read "$SOURCE/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
if [[ "$SOURCE_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Error: source bundle ID is '$SOURCE_BUNDLE_ID', expected '$EXPECTED_BUNDLE_ID'."
    echo "Are you pointing at the right .app?"
    exit 1
fi

echo "Source verified: $SOURCE ($SOURCE_BUNDLE_ID)"

# ── 2. Quit running instance ──────────────────────────────────────────────────

if pgrep -x "$APP_PROCESS_NAME" > /dev/null 2>&1; then
    echo "Quitting running '$APP_PROCESS_NAME'..."
    # Try graceful quit via AppleScript first.
    osascript -e "quit app \"$APP_PROCESS_NAME\"" 2>/dev/null || true
    # Give it 3 seconds to exit cleanly.
    sleep 3
    # If still running, force-kill.
    if pgrep -x "$APP_PROCESS_NAME" > /dev/null 2>&1; then
        echo "  Still running — sending SIGKILL..."
        pkill -KILL -x "$APP_PROCESS_NAME" 2>/dev/null || true
        sleep 1
    fi
    echo "  Done."
else
    echo "No running '$APP_PROCESS_NAME' found — skipping quit."
fi

# ── 3. Remove old bundle ──────────────────────────────────────────────────────
# CRITICAL: rm -rf first. cp -R into an existing .app nests source inside target.

if [[ -e "$TARGET" ]]; then
    echo "Removing old bundle: $TARGET"
    rm -rf "$TARGET"
fi

# ── 4. Copy new bundle ───────────────────────────────────────────────────────

echo "Copying $SOURCE → /Applications/"
cp -R "$SOURCE" "/Applications/"

# ── 5. Clear Gatekeeper quarantine ───────────────────────────────────────────

echo "Clearing quarantine attribute..."
xattr -rd com.apple.quarantine "$TARGET" 2>/dev/null || true

# ── 6. Verify installed bundle ───────────────────────────────────────────────

INSTALLED_BUNDLE_ID=$(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
if [[ "$INSTALLED_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "ERROR: Installed bundle ID mismatch: got '$INSTALLED_BUNDLE_ID', expected '$EXPECTED_BUNDLE_ID'."
    echo "Installation may be corrupt — check $TARGET manually."
    exit 1
fi

INSTALLED_VERSION=$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
INSTALLED_BUILD=$(defaults read "$TARGET/Contents/Info" CFBundleVersion 2>/dev/null || echo "unknown")

# ── 7. No-nesting assertion ───────────────────────────────────────────────────
# After cp -R into the PARENT dir, the bundle must NOT contain itself as a child.
# If nesting occurred, source was accidentally copied INTO target instead of replacing it.

NESTED_CHECK="$TARGET/$(basename "$SOURCE")"
if [[ -e "$NESTED_CHECK" ]]; then
    echo "ERROR: Nesting detected — $NESTED_CHECK exists inside the installed bundle!"
    echo "This means the install procedure copied source INTO target instead of replacing it."
    echo "Remove the nested bundle manually: rm -rf \"$NESTED_CHECK\""
    exit 1
fi
echo "No-nesting assertion: OK"

# ── 8. Launch-verify (optional) ──────────────────────────────────────────────
# Open the installed app and assert lsappinfo shows the correct bundle path.
# This catches the case where the OS launches a stale DerivedData copy instead.

if [[ "$LAUNCH_VERIFY" == "true" ]]; then
    echo ""
    echo "Launch-verify: opening $TARGET..."
    open "$TARGET"

    # Wait up to 10 seconds for the process to appear and register with lsappinfo.
    VERIFY_TIMEOUT=10
    VERIFY_ELAPSED=0
    BUNDLE_PATH=""
    while [[ $VERIFY_ELAPSED -lt $VERIFY_TIMEOUT ]]; do
        sleep 1
        VERIFY_ELAPSED=$((VERIFY_ELAPSED + 1))
        # lsappinfo uses the display name; match case-insensitively to be safe.
        BUNDLE_PATH=$(lsappinfo list 2>/dev/null \
            | awk '/[Mm]io [Ii]sland/{found=1} found && /bundle path/{print; exit}' \
            | sed 's/.*bundle path = *//' \
            | tr -d '"')
        if [[ -n "$BUNDLE_PATH" ]]; then
            break
        fi
    done

    if [[ -z "$BUNDLE_PATH" ]]; then
        echo "ERROR: Launch-verify failed — '$APP_PROCESS_NAME' did not appear in lsappinfo after ${VERIFY_TIMEOUT}s."
        echo "The app may have crashed on launch, or lsappinfo could not find it."
        exit 1
    fi

    # Normalize trailing slash differences for comparison.
    EXPECTED_BUNDLE_PATH="$TARGET"
    ACTUAL_NORMALIZED="${BUNDLE_PATH%/}"
    EXPECTED_NORMALIZED="${EXPECTED_BUNDLE_PATH%/}"

    if [[ "$ACTUAL_NORMALIZED" != "$EXPECTED_NORMALIZED" ]]; then
        echo "ERROR: Launch-verify FAILED — running instance is from the wrong path!"
        echo "   Expected: $EXPECTED_BUNDLE_PATH"
        echo "   Actual:   $BUNDLE_PATH"
        echo "The OS may have launched a stale DerivedData or quarantined copy."
        exit 1
    fi

    echo "Launch-verify: OK — running from $BUNDLE_PATH"
fi

echo ""
echo "✅ Install complete."
echo "   Path:    $TARGET"
echo "   Version: $INSTALLED_VERSION ($INSTALLED_BUILD)"
echo "   Bundle:  $INSTALLED_BUNDLE_ID"
if [[ "$LAUNCH_VERIFY" == "true" ]]; then
    echo "   Running: $BUNDLE_PATH (launch-verify passed)"
fi
echo ""
if [[ "$LAUNCH_VERIFY" != "true" ]]; then
    echo "To launch and verify running path:"
    echo "   open \"$TARGET\""
    echo "   # After launch, run the following to confirm the process is from /Applications:"
    echo "   lsappinfo list | grep -A2 'Mio Island' | grep 'bundle path'"
    echo "   # Expected: bundle path = $TARGET"
    echo "   # Or re-run with --launch-verify to automate this check."
fi
