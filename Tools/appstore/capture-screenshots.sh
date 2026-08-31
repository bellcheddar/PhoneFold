#!/usr/bin/env bash
# Capture App Store screenshots of PhoneFold from a simulator.
#
# Driven entirely by launch environment, because `simctl` cannot touch a simulator: there is no
# input injection for any Apple platform, so a control reachable only by tapping is a control no
# capture can ever show in a state other than its default. `StageView` reads PHONEFOLD_ENGINE,
# PHONEFOLD_TRAJECTORY, PHONEFOLD_ACCESSION, PHONEFOLD_COLOUR and PHONEFOLD_STYLE for exactly
# this reason, and each of them says so where it is read.
#
#   ./Tools/appstore/capture-screenshots.sh <device-udid> <output-dir>
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:?usage: capture-screenshots.sh <udid> <out-dir>}"
OUT="${2:?}"
BUNDLE="${3:-com.mdeller.phonefold}"
mkdir -p "$OUT"

# Apple's own convention, and it also stops the clock differing between device sets shot minutes
# apart - which is the sort of inconsistency a reviewer notices and nobody else does.
xcrun simctl status_bar "$UDID" override --time "9:41" \
    --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true

shot() {
    local name="$1"; shift
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    # SIMCTL_CHILD_ is how environment reaches the app; `--setenv` is rejected outright with
    # "Invalid device: --setenv", which reads like the device is wrong rather than the flag.
    env "$@" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
    python3 -c "import time; time.sleep(${SETTLE:-26})"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    echo "  $name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" 2>/dev/null \
        | awk '/pixel/{printf "%s ", $2}')"
}

echo "Capturing PhoneFold from $UDID into $OUT"
# A fold in progress, in the app's own colouring: the picture the app is for.
shot "1-fold"      SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=ubiquitin
# Confidence colouring on a bigger protein - the orange-to-blue pLDDT ramp is the one image a
# structural biologist recognises instantly.
shot "2-confidence" SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=gfp \
                    SIMCTL_CHILD_PHONEFOLD_COLOUR=confidence
# The generative engine: a backbone that did not exist until the device made it.
shot "3-generated" SIMCTL_CHILD_PHONEFOLD_ENGINE=generative
# Hydrophobicity on the demo structure, which is the core packing made visible.
shot "4-core"      SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=trp_cage \
                   SIMCTL_CHILD_PHONEFOLD_COLOUR=hydrophobicity
# A different voice on a long protein, so the score controls are in a different state.
shot "5-voice"     SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=lysozyme \
                   SIMCTL_CHILD_PHONEFOLD_STYLE=surf \
                   SIMCTL_CHILD_PHONEFOLD_COLOUR=rainbow
