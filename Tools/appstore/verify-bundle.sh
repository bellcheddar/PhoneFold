#!/usr/bin/env bash
# Check that a built PhoneFold app actually contains what it needs to work.
#
# **ARCHIVE SUCCEEDED says nothing about the contents.** An archive missing its Core ML model
# builds, signs and uploads perfectly, and the app cannot do the one thing it exists to do -
# the failure arrives on a stranger's phone as a button that does nothing. Everything checked
# here is a resource the app reads by name at run time, so a rename or a dropped build phase
# is silent until someone taps.
set -uo pipefail
cd "$(dirname "$0")/../.."

APP="${1:?usage: verify-bundle.sh /path/to/PhoneFold.app}"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }
RES="$APP"
[ -d "$APP/Contents/Resources" ] && RES="$APP/Contents/Resources"

fail=0
note() { printf "  %-46s %s\n" "$1" "$2"; }

check() {
    local path="$1" min="${2:-1}"
    if [ ! -e "$path" ]; then note "$(basename "$path")" "MISSING"; fail=1; return; fi
    local size; size=$(du -sk "$path" | cut -f1)
    if [ "$size" -lt "$min" ]; then
        note "$(basename "$path")" "TOO SMALL (${size} kB < ${min} kB)"; fail=1; return
    fi
    note "$(basename "$path")" "$(du -sh "$path" | cut -f1)"
}

echo "Verifying $(basename "$APP")"

echo "The generative engine:"
# Genie2Sampler.bundled() looks for this by name. Without it the Generate engine throws at the
# moment somebody presses the button, and nothing earlier says a word.
check "$RES/Genie2Step_L64.mlmodelc" 20000

echo "The gallery:"
# PLAN's twelve. The library enumerates .pftraj, so a missing one is a shorter gallery rather
# than an error - which is exactly why the count is asserted rather than eyeballed.
count=$(find "$RES" -maxdepth 1 -name "*.pftraj" | wc -l | tr -d ' ')
if [ "$count" -lt 12 ]; then
    note "trajectories" "ONLY $count, expected 12"; fail=1
else
    note "trajectories" "$count .pftraj"
fi

echo "The score:"
# The app still folds and draws without these; it just cannot sing, which is half of what it is.
styles=$(find "$RES/Styles" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
if [ "$styles" -lt 5 ]; then
    note "Styles" "ONLY $styles style profiles, expected 5"; fail=1
else
    note "Styles" "$styles style profiles"
fi
check "$RES/Notes" 1

PLIST="$APP/Info.plist"; [ -f "$APP/Contents/Info.plist" ] && PLIST="$APP/Contents/Info.plist"

echo "Required by Apple:"
check "$RES/Assets.car" 20
# CFBundleIconName is written by hand because XcodeGen supplies the Info.plist; Xcode injects it
# only under GENERATE_INFOPLIST_FILE. Without it the upload is refused, and nothing before the
# upload complains.
PLIST="$APP/Info.plist"; [ -f "$APP/Contents/Info.plist" ] && PLIST="$APP/Contents/Info.plist"
icon=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$PLIST" 2>/dev/null || echo "")
[ -n "$icon" ] && note "CFBundleIconName" "$icon" || { note "CFBundleIconName" "MISSING"; fail=1; }
check "$RES/PrivacyInfo.xcprivacy" 1

# **Only the iOS archive carries them, and asking of the wrong platform is worse than not
# asking.** A visionOS app embeds no watch app and no iOS widget extension, so demanding them
# there fails a perfectly good archive - which this script did, and refused to upload it. A
# check that cries wolf gets ignored, and the reason this one exists is that it caught a
# genuinely missing watch app on iOS.
PLATFORM=$(/usr/libexec/PlistBuddy -c "Print :DTPlatformName" "$PLIST" 2>/dev/null || echo "")
if [ "$PLATFORM" = "iphoneos" ] || [ "$PLATFORM" = "iphonesimulator" ]; then
    echo "Embedded:"
    for kind in "Watch/PhoneFoldWatch.app" "PlugIns/PhoneFoldWidgets.appex"; do
        if [ -e "$APP/$kind" ]; then note "$(basename "$kind")" "$(du -sh "$APP/$kind" | cut -f1)"
        else note "$(basename "$kind")" "MISSING"; fail=1; fi
    done
    # The Fold of the Day is the one thing the watch app does with no phone at all.
    WATCH="$APP/Watch/PhoneFoldWatch.app"
    [ -d "$WATCH" ] && check "$WATCH/FoldOfTheDay.json" 100
else
    echo "Embedded:"
    note "n/a" "$PLATFORM carries no watch app or widget extension"
fi

echo
if [ "$fail" = 0 ]; then echo "bundle: OK"; else echo "bundle: INCOMPLETE"; fi
exit "$fail"
