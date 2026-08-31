#!/usr/bin/env bash
# Build release archives for the App Store.
#
# The iOS scheme embeds the watch app and its widget extension, so one archive
# covers iPhone, iPad, Watch and the complication. macOS and visionOS archive
# separately.
#
#   ./Tools/archive.sh          # iOS (default)
#   ./Tools/archive.sh macos
#   ./Tools/archive.sh visionos
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:-ios}"
OUT="build/archives"
mkdir -p "$OUT"

case "$PLATFORM" in
  ios)      SCHEME="PfamIE";           DEST="generic/platform=iOS" ;;
  macos)    SCHEME="PfamIE-macOS";     DEST="generic/platform=macOS" ;;
  visionos) SCHEME="PfamIE-visionOS";  DEST="generic/platform=visionOS" ;;
  *) echo "usage: archive.sh [ios|macos|visionos]" >&2; exit 2 ;;
esac

ARCHIVE="$OUT/PfamIE-$PLATFORM.xcarchive"
rm -rf "$ARCHIVE"

# Regenerate first: the .xcodeproj is derived, and archiving a stale one is a
# quiet way to ship yesterday's configuration.
./Tools/generate-project.sh >/dev/null

echo "Archiving $SCHEME for $PLATFORM..."
xcodebuild archive \
    -project PfamIE.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "$DEST" \
    -archivePath "$ARCHIVE" \
    | grep -E "error:|warning: .*(signing|provisioning)|\*\* ARCHIVE" || true

if [ ! -d "$ARCHIVE" ]; then
    echo "No archive was produced." >&2
    exit 1
fi

echo
echo "Archive: $ARCHIVE"
echo "Now verify it. ARCHIVE SUCCEEDED says nothing about the contents:"
echo "  ./Tools/verify-archive.sh $ARCHIVE"
