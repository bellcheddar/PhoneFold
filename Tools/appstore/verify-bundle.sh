#!/usr/bin/env bash
# Check that a built PfamIE app actually contains what it needs to work.
#
# BUILD SUCCEEDED says nothing about the contents. An app that ships without
# its Core ML models or its centroid matrix builds cleanly, signs cleanly, and
# cannot do the one thing it exists to do. Negative-test this script by
# deleting a file from a bundle: it must fail.
set -uo pipefail

APP="${1:?usage: verify-bundle.sh /path/to/PfamIE.app}"
if [ -d "$APP/Contents/Resources" ]; then
    RES="$APP/Contents/Resources"          # macOS
else
    RES="$APP"                              # iOS, visionOS, watchOS
fi

fail=0
note() { printf '  %-42s %s\n' "$1" "$2"; }

check_file() {
    local path="$1" min="$2"
    if [ ! -e "$path" ]; then
        note "$(basename "$path")" "MISSING"; fail=1; return
    fi
    local size
    size=$(du -sk "$path" | cut -f1)
    if [ "$size" -lt "$min" ]; then
        note "$(basename "$path")" "TOO SMALL (${size} kB < ${min} kB)"; fail=1; return
    fi
    note "$(basename "$path")" "$(du -sh "$path" | cut -f1)"
}

echo "Verifying $(basename "$APP")"
echo "Models:"
check_file "$RES/PfamIEProteinEmbedder.mlmodelc" 8000
check_file "$RES/PfamIETextEmbedder.mlmodelc"    8000

echo "Data:"
# Sizes come from the manifest the forge wrote, not from constants here.
# Hard-coded floors were calibrated for float16 and rejected a correct int8
# bundle the moment the format changed: a check that has to be edited every
# time the data changes will eventually be edited to pass.
if [ -e "$RES/bundle/manifest.json" ]; then DATA="$RES/bundle"; else DATA="$RES"; fi
check_file "$DATA/manifest.json" 1
check_file "$DATA/pfam.sqlite" 40000

SIZES=$("$(dirname "$0")/manifest_sizes.py" "$DATA/manifest.json" 2>&1)
if [ $? -ne 0 ] || [ -z "$SIZES" ]; then
    # An unreadable manifest must fail loudly. An earlier version let this
    # path print nothing and still report OK, which passed a bundle with a
    # deliberately truncated matrix.
    note "manifest" "UNREADABLE: $SIZES"; fail=1
else
    while IFS='|' read -r name expected; do
        [ -z "$name" ] && continue
        if [ ! -f "$DATA/$name" ]; then
            note "$name" "MISSING"; fail=1; continue
        fi
        actual=$(stat -f%z "$DATA/$name")
        if [ "$actual" != "$expected" ]; then
            note "$name" "SIZE $actual, manifest says $expected"; fail=1
        else
            note "$name" "$(du -sh "$DATA/$name" | cut -f1) (matches manifest)"
        fi
    done <<< "$SIZES"
fi

echo "Structure viewer:"
if [ -e "$RES/bundle/molstar" ]; then MOL="$RES/bundle/molstar"; else MOL="$RES/molstar"; fi
check_file "$MOL/molstar.js" 3000

echo "Icon:"
# Where the compiled icon lives differs by platform, and an empty icon set
# builds cleanly on all of them. visionOS is the awkward one: it takes a
# layered AppIcon.solidimagestack, not a flat PNG, and compiles the layers into
# Assets.car rather than writing files at the bundle root.
if [ -f "$RES/AppIcon.icns" ]; then
    note "AppIcon.icns" "$(du -sh "$RES/AppIcon.icns" | cut -f1)"          # macOS
elif ls "$RES"/AppIcon60x60@2x.png >/dev/null 2>&1; then                   # iOS
    for icon in "$RES"/AppIcon60x60@2x.png "$RES"/AppIcon76x76@2x~ipad.png; do
        if [ -f "$icon" ]; then
            note "$(basename "$icon")" "$(du -sh "$icon" | cut -f1)"
        else
            note "$(basename "$icon")" "MISSING"; fail=1
        fi
    done
elif [ -f "$RES/Assets.car" ]; then                                        # visionOS
    LAYERS=$(xcrun assetutil --info "$RES/Assets.car" 2>/dev/null \
             | grep -oE 'AppIcon[\\/]+(Front|Middle|Back)' | sort -u | wc -l | tr -d ' ')
    if [ "${LAYERS:-0}" -ge 3 ]; then
        note "AppIcon.solidimagestack" "3 layers in Assets.car"
    elif grep -q AppIcon "$RES/Info.plist" 2>/dev/null; then
        note "app icon" "declared but only $LAYERS layers compiled"; fail=1
    else
        note "app icon" "MISSING"; fail=1
    fi
else
    note "app icon" "MISSING"; fail=1
fi

echo "Signing:"
authority=$(codesign -dvv "$APP" 2>&1 | grep "^Authority=" | head -1)
if [ -n "$authority" ]; then note "authority" "${authority#Authority=}"; else note "authority" "unsigned (fine for a debug build)"; fi

echo
if [ "$fail" -eq 0 ]; then
    echo "OK: $(du -sh "$APP" | cut -f1) bundle, everything present."
else
    echo "FAILED: the bundle is missing something it needs to run." >&2
fi
exit "$fail"
