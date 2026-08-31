#!/usr/bin/env bash
# Export an archive and upload it to App Store Connect for TestFlight.
#
# Requires the App Store Connect app record to exist. That is the one step
# Apple's API forbids (POST /v1/apps returns 403 FORBIDDEN_ERROR), so it is
# created by hand once. Check with:
#
#     .venv/bin/python Tools/asc_api.py status
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="${1:-build/archives/PfamIE-ios.xcarchive}"
EXPORT_DIR="build/export"

if [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${ASC_KEY_ID:-}" ]; then
    echo "Credentials are not loaded. Run:" >&2
    echo "  set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a" >&2
    exit 1
fi

./Tools/verify-archive.sh "$ARCHIVE"

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
# Manual signing means the export has to be told which profile belongs to which
# bundle id. Without the mapping xcodebuild fails with the unhelpful
# 'exportArchive "PfamIE.app" requires a provisioning profile.'
case "$ARCHIVE" in
  *macos*)    PROFILES='<key>com.mdeller.pfamie</key><string>PfamIE macOS App Store</string>' ;;
  *visionos*) PROFILES='<key>com.mdeller.pfamie</key><string>PfamIE visionOS App Store</string>' ;;
  *)          PROFILES='<key>com.mdeller.pfamie</key><string>PfamIE App Store</string>
        <key>com.mdeller.pfamie.watchkitapp</key><string>PfamIE watchOS App Store</string>
        <key>com.mdeller.pfamie.watchkitapp.widget</key><string>PfamIE watchOS Widget App Store</string>' ;;
esac

cat > "$EXPORT_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>$APPLE_TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
    <key>provisioningProfiles</key>
    <dict>
        $PROFILES
    </dict>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "Exporting..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_DIR/ExportOptions.plist" \
    | grep -E "error:|EXPORT" || true

PACKAGE=$(find "$EXPORT_DIR" -maxdepth 1 \( -name "*.ipa" -o -name "*.pkg" \) | head -1)
if [ -z "$PACKAGE" ]; then
    echo "Export produced no .ipa or .pkg." >&2
    exit 1
fi
echo "Exported $PACKAGE ($(du -h "$PACKAGE" | cut -f1))"

case "$PACKAGE" in
    *.pkg) TYPE="macos" ;;
    *)     TYPE="ios" ;;
esac

# altool only looks for the signing key in ./private_keys, ~/private_keys,
# ~/.private_keys and ~/.appstoreconnect/private_keys. The key is in none of
# them, so point at it rather than copying a private key around.
export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"

echo "Uploading to App Store Connect..."
set +e
OUTPUT=$(xcrun altool --upload-app -f "$PACKAGE" -t "$TYPE" \
             --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1)
STATUS=$?
set -e
echo "$OUTPUT"

if [ "$STATUS" -ne 0 ]; then
    if echo "$OUTPUT" | grep -q "Cannot determine the Apple ID"; then
        cat >&2 <<'HINT'

That error blames the bundle ID and means something else: there is no App
Store Connect app record for com.mdeller.pfamie yet.

Create it once at https://appstoreconnect.apple.com (Apps -> + -> New App).
The bundle ID is already registered. The App Store name is globally unique
and may be taken, which is why this step cannot be automated.

Then run this script again.
HINT
    fi
    exit "$STATUS"
fi

echo
echo "Uploaded. It will appear in TestFlight after Apple finishes processing."
