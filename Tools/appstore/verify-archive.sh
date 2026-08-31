#!/usr/bin/env bash
# Check a release archive actually contains a working app.
#
# ARCHIVE SUCCEEDED says nothing about the contents. An archive missing its
# Core ML models builds, signs and uploads perfectly, and the app cannot do the
# one thing it exists to do. This wraps verify-bundle.sh, which is itself
# negative-tested, and adds the checks that only matter for a release: the
# signing authority and the embedded provisioning profile.
set -uo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="${1:-build/archives/PfamIE-ios.xcarchive}"
if [ ! -d "$ARCHIVE" ]; then
    echo "No archive at $ARCHIVE. Run ./Tools/archive.sh first." >&2
    exit 1
fi

APP=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -1)
if [ -z "$APP" ]; then
    echo "The archive contains no application." >&2
    exit 1
fi

fail=0
./Tools/verify-bundle.sh "$APP" || fail=1

echo
echo "Release checks:"
authority=$(codesign -dvv "$APP" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2-)
case "$authority" in
    "Apple Distribution"*) printf '  %-42s %s\n' "signing authority" "$authority" ;;
    "") printf '  %-42s %s\n' "signing authority" "UNSIGNED"; fail=1 ;;
    *)  printf '  %-42s %s\n' "signing authority" "NOT DISTRIBUTION: $authority"; fail=1 ;;
esac

PROFILE=$(find "$APP" -maxdepth 1 -name "embedded.mobileprovision" | head -1)
if [ -n "$PROFILE" ]; then
    NAME=$(security cms -D -i "$PROFILE" 2>/dev/null \
           | plutil -extract Name raw - 2>/dev/null || echo "unreadable")
    printf '  %-42s %s\n' "embedded profile" "$NAME"
else
    printf '  %-42s %s\n' "embedded profile" "none (fine for a macOS archive)"
fi

# Every embedded extension has to be signed too, or the upload is rejected
# after the fact rather than here.
for ext in $(find "$APP" -name "*.appex" -maxdepth 4); do
    a=$(codesign -dvv "$ext" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2-)
    printf '  %-42s %s\n' "$(basename "$ext")" "${a:-UNSIGNED}"
    [ -z "$a" ] && fail=1
done

echo
if [ "$fail" -eq 0 ]; then
    echo "OK: archive is complete and signed for distribution."
else
    echo "FAILED: do not upload this archive." >&2
fi
exit "$fail"
