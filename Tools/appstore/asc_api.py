#!/usr/bin/env python3
"""
A thin App Store Connect API client, enough for what PhoneFold needs.

Bundle identifiers and provisioning profiles CAN be created over the API, so
they are, rather than clicked. The app record itself cannot:

    POST /v1/apps -> 403 FORBIDDEN_ERROR
    "The resource 'apps' does not allow 'CREATE'."

That one step stays manual, and it carries a decision that is genuinely the
author's: the App Store name is globally unique and may be taken.

Credentials come from the skill's credentials.env and are never inlined:

    set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

from pathlib import Path

import jwt

BASE = "https://api.appstoreconnect.apple.com/v1"

# From the environment, so no account identifier lives in this public repo.
TEAM_ID = os.environ.get("APPLE_TEAM_ID", "")

# macOS deliberately shares com.mdeller.phonefold with iOS, so one universal app
# record covers iPhone, iPad and Mac. A separate .mac identifier would split
# them into two store listings.
#
# **PhoneFold Studio is not in this list on purpose.** It is a *second product*
# with its own identifier and its own listing - PLAN.md calls it "PhoneFold
# Studio" and says never to rename it for consistency - so it gets its own app
# record when its turn comes. This push is the PhoneFold record: iPhone, iPad,
# Watch, Vision Pro.
BUNDLE_IDS = [
    ("com.mdeller.phonefold", "PhoneFold", "IOS"),
    ("com.mdeller.phonefold.widgets", "PhoneFold Live Activity", "IOS"),
    ("com.mdeller.phonefold.watchkitapp", "PhoneFold Watch App", "IOS"),
    # NOT ".complication": Apple reserves that word in the App ID namespace and
    # rejects it at any depth with "is not available", while ".widget" and
    # ".extension" under the same parent are accepted. The error names the
    # identifier, not the reason, so this is worth recording.
    ("com.mdeller.phonefold.watchkitapp.widget", "PhoneFold Watch Widget", "IOS"),
    ("com.mdeller.phonefold.vision", "PhoneFold for Vision Pro", "IOS"),
]


def token() -> str:
    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    key_path = os.environ.get("ASC_KEY_PATH")
    if not TEAM_ID:
        sys.exit("APPLE_TEAM_ID is not set. Source your credentials file first.")
    if not (key_id and issuer and key_path):
        sys.exit(
            "ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be set. Run:\n"
            "  set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a"
        )
    with open(key_path) as handle:
        private_key = handle.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None, auth: str | None = None):
    auth = auth or token()
    request = urllib.request.Request(
        f"{BASE}{path}" if path.startswith("/") else path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={
            "Authorization": f"Bearer {auth}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise RuntimeError(f"{method} {path} -> {error.code}: {detail}") from None


def existing_bundle_ids(auth: str) -> dict[str, str]:
    out = {}
    payload = call("GET", "/bundleIds?limit=200", auth=auth)
    for item in payload.get("data", []):
        out[item["attributes"]["identifier"]] = item["id"]
    return out


def ensure_bundle_ids() -> dict[str, str]:
    auth = token()
    have = existing_bundle_ids(auth)
    result = {}
    for identifier, name, platform in BUNDLE_IDS:
        if identifier in have:
            print(f"  present  {identifier}")
            result[identifier] = have[identifier]
            continue
        created = call("POST", "/bundleIds", {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": identifier,
                    "name": name,
                    "platform": platform,
                },
            }
        }, auth=auth)
        result[identifier] = created["data"]["id"]
        print(f"  created  {identifier}")
    return result


PROFILES = [
    ("PhoneFold App Store", "com.mdeller.phonefold", "IOS_APP_STORE"),
    ("PhoneFold Widgets App Store", "com.mdeller.phonefold.widgets", "IOS_APP_STORE"),
    ("PhoneFold watchOS App Store", "com.mdeller.phonefold.watchkitapp", "IOS_APP_STORE"),
    ("PhoneFold watchOS Widget App Store",
     "com.mdeller.phonefold.watchkitapp.widget", "IOS_APP_STORE"),
    # visionOS has its own identifier here, unlike PfamIE: PhoneFold on Vision Pro is a
    # separate target with its own bundle id because it ships different resources - three
    # Genie 2 length buckets and no widget extension.
    ("PhoneFold visionOS App Store", "com.mdeller.phonefold.vision", "IOS_APP_STORE"),
    # macOS shares the bundle id but needs its own profile type.
    ("PhoneFold macOS App Store", "com.mdeller.phonefold", "MAC_APP_STORE"),
]


def distribution_certificate(auth: str) -> str:
    payload = call("GET", "/certificates?limit=200", auth=auth)
    for item in payload.get("data", []):
        kind = item["attributes"].get("certificateType")
        if kind in ("DISTRIBUTION", "IOS_DISTRIBUTION"):
            return item["id"]
    raise RuntimeError("no Apple Distribution certificate in this account")


def ensure_profiles() -> None:
    auth = token()
    bundle_ids = existing_bundle_ids(auth)
    certificate = distribution_certificate(auth)

    have = {}
    payload = call("GET", "/profiles?limit=200", auth=auth)
    for item in payload.get("data", []):
        have[item["attributes"]["name"]] = item["attributes"].get("profileState")

    for name, identifier, kind in PROFILES:
        if name in have:
            print(f"  present  {name} ({have[name]})")
            continue
        if identifier not in bundle_ids:
            print(f"  SKIP     {name}: bundle id {identifier} is not registered")
            continue
        call("POST", "/profiles", {
            "data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": kind},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds",
                                          "id": bundle_ids[identifier]}},
                    "certificates": {"data": [{"type": "certificates",
                                               "id": certificate}]},
                },
            }
        }, auth=auth)
        print(f"  created  {name}")


# Bundle ids that need the App Group so the watch app and its complication can
# share the last state the phone published. Without it the widget has its own
# container and the complication shows "no recent fold" for ever - see
# FoldComplicationStore, which says the same thing from the other end.
APP_GROUP_BUNDLE_IDS = [
    "com.mdeller.phonefold.watchkitapp",
    "com.mdeller.phonefold.watchkitapp.widget",
]

# Bundle ids that need iCloud, for the synced list of folds this account has run.
# See FoldLogStore: without the capability NSUbiquitousKeyValueStore accepts a
# write and returns nil on the read, silently.
ICLOUD_BUNDLE_IDS = [
    "com.mdeller.phonefold",
    "com.mdeller.phonefold.vision",
]


def ensure_capabilities() -> None:
    auth = token()
    ids = existing_bundle_ids(auth)
    for identifier in APP_GROUP_BUNDLE_IDS:
        if identifier not in ids:
            print(f"  SKIP     {identifier}: not registered")
            continue
        try:
            call("POST", "/bundleIdCapabilities", {
                "data": {
                    "type": "bundleIdCapabilities",
                    "attributes": {"capabilityType": "APP_GROUPS"},
                    "relationships": {
                        "bundleId": {"data": {"type": "bundleIds",
                                              "id": ids[identifier]}}
                    },
                }
            }, auth=auth)
            print(f"  enabled  APP_GROUPS on {identifier}")
        except RuntimeError as error:
            if "already exists" in str(error) or "ENTITY_ERROR" in str(error):
                print(f"  present  APP_GROUPS on {identifier}")
            else:
                print(f"  FAILED   {identifier}: {str(error)[:120]}")


def ensure_icloud() -> None:
    """Turn on iCloud for the identifiers that carry the ubiquity-kvstore entitlement.

    `ICLOUD` is the capability; the *container* is a separate resource and, like App Groups,
    has to be created and assigned by hand. What this buys is the capability being on, which is
    what stops signing failing with "provisioning profile does not include the
    com.apple.developer.ubiquity-kvstore-identifier entitlement".
    """
    auth = token()
    ids = existing_bundle_ids(auth)
    for identifier in ICLOUD_BUNDLE_IDS:
        if identifier not in ids:
            print(f"  SKIP     {identifier}: not registered")
            continue
        try:
            call("POST", "/bundleIdCapabilities", {
                "data": {
                    "type": "bundleIdCapabilities",
                    "attributes": {"capabilityType": "ICLOUD"},
                    "relationships": {
                        "bundleId": {"data": {"type": "bundleIds",
                                              "id": ids[identifier]}}
                    },
                }
            }, auth=auth)
            print(f"  enabled  ICLOUD on {identifier}")
        except RuntimeError as error:
            if "already exists" in str(error) or "ENTITY_ERROR" in str(error):
                print(f"  present  ICLOUD on {identifier}")
            else:
                print(f"  FAILED   {identifier}: {str(error)[:160]}")


def delete_profiles() -> None:
    """
    Profiles are immutable snapshots of the capabilities at creation time, so
    enabling a capability afterwards does nothing until they are regenerated.
    """
    auth = token()
    wanted = {name for name, _, _ in PROFILES}
    payload = call("GET", "/profiles?limit=200", auth=auth)
    for item in payload.get("data", []):
        if item["attributes"]["name"] in wanted:
            call("DELETE", f"/profiles/{item['id']}", auth=auth)
            print(f"  deleted  {item['attributes']['name']}")


def install_profiles() -> None:
    """
    Download the profiles and put them where Xcode looks.

    Manual signing resolves PROVISIONING_PROFILE_SPECIFIER against locally
    installed profiles, so creating them in the portal is only half the job.
    """
    import base64

    auth = token()
    destination = Path.home() / "Library/MobileDevice/Provisioning Profiles"
    destination.mkdir(parents=True, exist_ok=True)

    payload = call("GET", "/profiles?limit=200", auth=auth)
    wanted = {name for name, _, _ in PROFILES}
    for item in payload.get("data", []):
        attributes = item["attributes"]
        if attributes["name"] not in wanted:
            continue
        content = attributes.get("profileContent")
        if not content:
            print(f"  no content for {attributes['name']}")
            continue
        uuid = attributes.get("uuid") or item["id"]
        path = destination / f"{uuid}.mobileprovision"
        path.write_bytes(base64.b64decode(content))
        print(f"  installed  {attributes['name']}  -> {path.name}")


def app_group_ready(group: str = "group.com.mdeller.phonefold") -> bool:
    """
    True once the App Group is actually assigned to the bundle ids that need it.

    Checked by minting a throwaway provisioning profile and decoding it, which
    is the only thing that tells the truth. The obvious check does not work:
    the `APP_GROUPS` capability's `settings` field reads null whether or not a
    group is attached. It reads null for an identifier whose freshly generated
    profile plainly carries two groups, so a detector built on it waits for
    ever. Entitlements in a profile are ground truth; capability metadata is
    not.
    """
    import base64
    import subprocess
    import tempfile

    auth = token()
    ids = existing_bundle_ids(auth)
    certificate = distribution_certificate(auth)
    ready = True

    for identifier in APP_GROUP_BUNDLE_IDS:
        bundle = ids.get(identifier)
        if not bundle:
            print(f"  {identifier}: not registered")
            ready = False
            continue

        created = call("POST", "/profiles", {
            "data": {
                "type": "profiles",
                "attributes": {"name": f"probe-{identifier}", "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate}]},
                },
            }
        }, auth=auth)
        try:
            content = base64.b64decode(created["data"]["attributes"]["profileContent"])
            with tempfile.NamedTemporaryFile(suffix=".mobileprovision") as handle:
                handle.write(content)
                handle.flush()
                xml = subprocess.run(["security", "cms", "-D", "-i", handle.name],
                                     capture_output=True).stdout.decode("utf-8", "replace")
            if group in xml:
                print(f"  {identifier}: {group} assigned")
            else:
                print(f"  {identifier}: {group} NOT assigned")
                ready = False
        finally:
            call("DELETE", f"/profiles/{created['data']['id']}", auth=auth)

    return ready


def create_installer_certificate() -> None:
    """
    Create a Mac Installer Distribution certificate.

    Exporting a Mac App Store package needs one, and `xcodebuild` fails with
    'No signing certificate "Mac Installer Distribution" found'. The API can
    issue it from a certificate signing request, so the private key is
    generated here, never leaves this machine, and goes straight into the login
    keychain with the issued certificate.
    """
    import base64
    import subprocess
    import tempfile

    auth = token()
    for item in call("GET", "/certificates?limit=200", auth=auth).get("data", []):
        if item["attributes"].get("certificateType") == "MAC_INSTALLER_DISTRIBUTION":
            print("  present  Mac Installer Distribution")
            return

    with tempfile.TemporaryDirectory() as work:
        key = Path(work) / "installer.key"
        csr = Path(work) / "installer.csr"
        crt = Path(work) / "installer.cer"

        subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"],
                       check=True, capture_output=True)
        subprocess.run([
            "openssl", "req", "-new", "-key", str(key), "-out", str(csr),
            "-subj", "/CN=PfamIE Mac Installer/O=Marc Deller/C=GB",
        ], check=True, capture_output=True)

        created = call("POST", "/certificates", {
            "data": {
                "type": "certificates",
                "attributes": {
                    "certificateType": "MAC_INSTALLER_DISTRIBUTION",
                    "csrContent": csr.read_text(),
                },
            }
        }, auth=auth)
        crt.write_bytes(base64.b64decode(
            created["data"]["attributes"]["certificateContent"]))

        # -A so codesign and productbuild can use it without a prompt per call.
        for path in (key, crt):
            subprocess.run(["security", "import", str(path),
                            "-k", str(Path.home() / "Library/Keychains/login.keychain-db"),
                            "-A"], check=False, capture_output=True)

    found = subprocess.run(["security", "find-identity", "-v"],
                           capture_output=True, text=True).stdout
    if "Mac Installer Distribution" in found or "3rd Party Mac Developer Installer" in found:
        print("  created  Mac Installer Distribution, imported into the login keychain")
    else:
        print("  created at Apple, but the keychain import did not take. "
              "Double-click the certificate in Keychain Access to finish.")


def app_records() -> list[dict]:
    payload = call("GET", "/apps?limit=200")
    return [
        {
            "bundleId": item["attributes"].get("bundleId"),
            "name": item["attributes"].get("name"),
            "sku": item["attributes"].get("sku"),
            "id": item["id"],
        }
        for item in payload.get("data", [])
    ]


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "status"

    if command == "bundle-ids":
        ensure_bundle_ids()

    elif command == "profiles":
        ensure_profiles()

    elif command == "installer-certificate":
        create_installer_certificate()

    elif command == "appgroup-status":
        sys.exit(0 if app_group_ready() else 1)

    elif command == "capabilities":
        ensure_capabilities()
        ensure_icloud()

    elif command == "refresh-profiles":
        # Capability first, then a clean regeneration, then install: a profile
        # created before the capability was enabled will not carry it.
        ensure_capabilities()
        ensure_icloud()
        delete_profiles()
        ensure_profiles()
        install_profiles()

    elif command == "install-profiles":
        install_profiles()

    elif command == "status":
        apps = app_records()
        target = [a for a in apps if a["bundleId"] == "com.mdeller.phonefold"]
        print(f"team {TEAM_ID}, {len(apps)} app records visible")
        if target:
            print(f"  PhoneFold app record EXISTS: {target[0]}")
        else:
            print("  PhoneFold app record: NOT FOUND")
            print("  POST /v1/apps returns 403 for every key, including Admin, so this is")
            print("  the one step the API cannot take. Create it once at")
            print("  https://appstoreconnect.apple.com -> Apps -> + -> New App")
            print("  Bundle ID: com.mdeller.pfamie")
            print("  The App Store name is globally unique, so it must be chosen "
                  "there and may be taken.")
        print("\n  Existing records:")
        for a in sorted(apps, key=lambda a: a["bundleId"] or ""):
            print(f"    {a['bundleId']:42s} {a['name']}")

    else:
        sys.exit(f"unknown command: {command}")
