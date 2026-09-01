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
    python3 -c "import time; time.sleep(${SETTLE})"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    echo "  $name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" 2>/dev/null \
        | awk '/pixel/{printf "%s ", $2}')"
}

# **The settle has to outlast the fold, and the fold is not fast.** Every gallery entry is a
# *native state* rather than a trajectory to replay: choosing one makes the device fold it, so
# the stage is empty until the physics arrives. The first run of this used 26 seconds against
# ubiquitin, which takes about 150, and produced five screenshots of an empty stage with a
# progress bar reading 0.0 ms. Nothing about that looks like a timing problem - it looks like
# the app failing to draw.
#
# So the proteins here are the short ones, chosen by their measured fold times (METRICS.md,
# P5b-06): trp-cage 9 s, WW domain and villin about 30, protein G 77.
#
# **And the app has to be a Release build.** A debug Swift build is about 36x slower for
# compute-heavy code, and a fold is 2,000,000 integration steps of nothing but arithmetic - so
# a Debug capture never finishes one however long the settle is. 115 seconds against trp-cage,
# which folds in 9, still produced five empty stages, and the second failure looked exactly
# like the first. `archive.sh` builds Release; so must this.
SETTLE="${SETTLE:-70}"

echo "Capturing PhoneFold from $UDID into $OUT (settle ${SETTLE}s)"
# The demo structure folding, in the app's own colouring: the picture the app is for.
shot "1-fold"       SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=trp_cage
# Confidence colouring - the orange-to-blue pLDDT ramp is the one image a structural biologist
# recognises instantly - on a protein with a real secondary structure to show.
shot "2-confidence" SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=protein_g_b1 \
                    SIMCTL_CHILD_PHONEFOLD_COLOUR=confidence
# The generative engine: a backbone that did not exist until the device made it.
shot "3-generated"  SIMCTL_CHILD_PHONEFOLD_ENGINE=generative
# Hydrophobicity, which is the core packing made visible.
shot "4-core"       SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=villin_hp36 \
                    SIMCTL_CHILD_PHONEFOLD_COLOUR=hydrophobicity
# A different voice, so the score controls are in a different state.
shot "5-voice"      SIMCTL_CHILD_PHONEFOLD_TRAJECTORY=ww_domain \
                    SIMCTL_CHILD_PHONEFOLD_STYLE=surf \
                    SIMCTL_CHILD_PHONEFOLD_COLOUR=rainbow
