#!/usr/bin/env bash
# Capture App Store screenshots from the running Mac app.
#
# Uses the same DEBUG launch arguments as the simulator capture, passed through
# `open --args`. On a Retina display screencapture yields 2x, which is 2880x1800
# and a valid App Store size in its own right.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-assets/screenshots/macos}"
APP=$(find ~/Library/Developer/Xcode/DerivedData/PfamIE-*/Build/Products/Debug \
      -maxdepth 1 -name "PfamIE.app" | head -1)
mkdir -p "$OUT"

SRC="MGSNKSKPKDASQRRRSLEPAENVHGAGGGAFPASQTPSKPASADGHRGPSAAFAPAAAEPKLFGGFNSSDTVTSPQRAGPLAGGVTTFVALYDYESRTETDLSFKKGERLQIVNNTEGDWWLAHSLSTGQTGYIPSNYVAPSDSIQAEEWYFGKITRRESERLLLNAENPRGTFLVRESETTKGAYCLSVSDFDNAKGLNVKHYKIRKLDSGGFYITSRTQFNSLQQLVAYYSKHADGLCHRLTTVCPTSKPQTQGLAKDAWEIPRESLRLEVKLGQGCFGEVWMGTWNGTTRVAIKTLKPGTMSPEAFLQEAQVMKKLRHEKLVQLYAVVSEEPIYIVTEYMSKGSLLDFLKGETGKYLRLPQLVDMAAQIASGMAYVERMNYVHRDLRAANILVGENLVCKVADFGLARLIEDNEYTARQGAKFPIKWTAPEAALYGRFTIKSDVWSFGILLTELTTKGRVPYPGMVNREVLDQVERGYRMPCPPECPESLHDLMCQCWRKEPEERPTFEYLQAFLEDYFTSTEPQYQPGENL"

settle() { local n=0; until [ $n -ge "${1:-30}" ]; do n=$((n+1)); sleep 1; done; }

shot() {
    local name="$1"; shift
    pkill -x PfamIE 2>/dev/null || true
    sleep 2
    # macOS remembers the window frame, so a resized window from a previous
    # shot carries over and the captures come out at different sizes. Clearing
    # the saved frame makes every launch start at the declared default.
    defaults delete com.mdeller.pfamie 2>/dev/null || true
    open -a "$APP" --args "$@"
    settle 32
    # Take the largest PfamIE window: the app can have an ornament or a sheet
    # open, and the main window is always the biggest.
    local id
    id=$(/tmp/winid | cut -d' ' -f1) || true
    if [ -z "$id" ]; then
        # One retry: a cold launch that has to map 148 MB of assets can miss
        # the window by a couple of seconds.
        settle 20
        id=$(/tmp/winid | cut -d' ' -f1) || true
    fi
    [ -z "$id" ] && { echo "  no window for $name"; return; }
    # -o drops the drop shadow, which would otherwise arrive as transparency.
    screencapture -x -o -l "$id" "$OUT/$name.png"
    echo "  $name.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" \
        | awk '/pixel/{printf "%s ", $2}')"
}

shot "1-galaxy"
shot "2-oracle"     -PfamIESequence "$SRC"
shot "3-fieldguide" -PfamIEQuery "breaks down plastic"
shot "4-grammarian" -PfamIEFamily PF00017
shot "5-prospector" -PfamIETab prospector
pkill -x PfamIE 2>/dev/null || true
