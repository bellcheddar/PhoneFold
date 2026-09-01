#!/usr/bin/env bash
# Build release archives of PhoneFold for the App Store.
#
# The iOS scheme embeds the watch app, the complication and the Live Activity extension, so one
# archive covers iPhone, iPad, Watch and both widgets. visionOS archives separately even though
# it shares the bundle id - a bundle id spans platforms, an archive does not.
#
#   ./Tools/appstore/archive.sh            # iOS (default)
#   ./Tools/appstore/archive.sh visionos
#
# There is deliberately no macos here: PLAN's Mac surface is PhoneFold Studio, a second product
# with its own identifier and its own listing, and it ships when its turn comes.
set -euo pipefail
cd "$(dirname "$0")/../.."

PLATFORM="${1:-ios}"
OUT="build/archives"
APP_DIR="Apps/PhoneFold"
mkdir -p "$OUT"

case "$PLATFORM" in
  ios)      SCHEME="PhoneFold";       DEST="generic/platform=iOS" ;;
  visionos) SCHEME="PhoneFoldVision"; DEST="generic/platform=visionOS" ;;
  *) echo "usage: archive.sh [ios|visionos]" >&2; exit 2 ;;
esac

ARCHIVE="$PWD/$OUT/PhoneFold-$PLATFORM.xcarchive"
rm -rf "$ARCHIVE"

# Regenerate first: the .xcodeproj is derived from project.yml and is gitignored, so archiving a
# stale one is a quiet way to ship yesterday's configuration. The team id comes from the
# credentials file and is never written into this repository.
set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a
(cd "$APP_DIR" && xcodegen generate --quiet)

# DerivedData outside ~/Documents: iCloud puts extended attributes on everything under it and
# codesign then fails with "resource fork, Finder information, or similar detritus not allowed".
DD=/Users/dellboy/Library/Developer/PhoneFold-DerivedData

echo "Archiving $SCHEME for $PLATFORM..."
(cd "$APP_DIR" && xcodebuild archive \
    -project PhoneFold.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "$DEST" \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DD" \
    | grep -E "error:|warning: .*(signing|provisioning)|\*\* ARCHIVE" || true)

if [ ! -d "$ARCHIVE" ]; then
    echo "No archive was produced." >&2
    exit 1
fi

echo
echo "Archive: $ARCHIVE"
echo "Now verify it. ARCHIVE SUCCEEDED says nothing about the contents:"
echo "  ./Tools/appstore/verify-archive.sh $ARCHIVE"
