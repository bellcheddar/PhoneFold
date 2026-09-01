#!/usr/bin/env bash
# Capture App Store screenshots of PhoneFold on Apple Vision Pro.
#
# `simctl` cannot touch a visionOS simulator either, so the scene, the walk-in and the pinned
# residue all arrive through the launch environment - see `VisionControlView`, which explains
# why each variable exists.
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: capture-vision.sh <udid> <out-dir>}"
OUT="${2:?}"
BUNDLE="com.mdeller.phonefold.vision"
mkdir -p "$OUT"

shot() {
    local name="$1"; shift
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    env "$@" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
    python3 -c "import time; time.sleep(${SETTLE:-20})"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    echo "  $name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" 2>/dev/null \
        | awk '/pixel/{printf "%s ", $2}')"
}

echo "Capturing Vision Pro from $UDID into $OUT"
# The protein in a volume on a desk, beside the control window: the shared-space case.
shot "1-volume"    SIMCTL_CHILD_PHONEFOLD_VISION_AUTOSTART=volume
# The concert hall: the protein at room scale in an immersive space.
shot "2-immersive" SIMCTL_CHILD_PHONEFOLD_VISION_AUTOSTART=immersive
# Walked into the core, which is the picture nothing else in this app can take.
shot "3-core"      SIMCTL_CHILD_PHONEFOLD_VISION_AUTOSTART=immersive \
                   SIMCTL_CHILD_PHONEFOLD_VISION_WALK_IN=1
