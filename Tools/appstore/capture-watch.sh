#!/usr/bin/env bash
# Capture App Store screenshots of the PhoneFold watch app.
#
# **An iOS binary that embeds a watch app must ship a watch screenshot**, and App Store Connect
# only says so at "Add for Review".
#
# The watch app is a remote and a standalone Fold of the Day, and neither is reachable from a
# script by touching: watchOS has no input injection at all, so the third page of a vertical
# TabView cannot be reached. `WatchLaunch` reads PHONEFOLD_WATCH_SCREEN and
# PHONEFOLD_WATCH_AUTOPLAY for exactly this reason and says so where it is read.
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: capture-watch.sh <udid> <out-dir>}"
OUT="${2:?}"
BUNDLE="com.mdeller.phonefold.watchkitapp"
mkdir -p "$OUT"

shot() {
    local name="$1"; shift
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    env "$@" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
    python3 -c "import time; time.sleep(${SETTLE:-8})"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    echo "  $name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" 2>/dev/null \
        | awk '/pixel/{printf "%s ", $2}')"
}

echo "Capturing the watch app from $UDID into $OUT"
# The Fold of the Day, mid-fold: the one screen that works with no phone at all.
SETTLE=6 shot "1-daily" SIMCTL_CHILD_PHONEFOLD_WATCH_SCREEN=daily \
                        SIMCTL_CHILD_PHONEFOLD_WATCH_AUTOPLAY=1
# And at rest, so the caption and the invitation are both legible.
SETTLE=14 shot "2-daily-done" SIMCTL_CHILD_PHONEFOLD_WATCH_SCREEN=daily \
                              SIMCTL_CHILD_PHONEFOLD_WATCH_AUTOPLAY=1
# **No shot of the remote, and that is not an omission.** The remote is what the wrist is for
# when a phone is present, and with no paired phone the screen says "Phone not reachable" -
# which is the app being honest and a terrible advertisement. A simulator cannot pair, so the
# only way to capture it is on Marc's own devices; it is in BLOCKERS.md as a better third shot
# rather than shipped as an error message.
