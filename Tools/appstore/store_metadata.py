#!/usr/bin/env python3
"""
Fill in the App Store Connect listing for PhoneFold.

Everything here is metadata: names, descriptions, categories, pricing and
screenshots. It never submits for review, and it never touches a build.

    set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a
    .venv/bin/python Tools/store_metadata.py all
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc_api import call, token

BUNDLE_ID = "com.mdeller.phonefold"
LOCALE = "en-US"

PRIVACY_POLICY_URL = "https://bellcheddar.github.io/PhoneFold/privacy.html"
SUPPORT_URL = "https://github.com/bellcheddar/PhoneFold"
MARKETING_URL = "https://marcdeller.com"

# Required before review. Year and holder, no (c) symbol: Apple adds it.
COPYRIGHT = "2026 Marc C. Deller"

# Education first and Music second, in that order deliberately: PLAN.md's first line is that
# PhoneFold is "a concert, not a workbench", and a listing filed under Reference would be
# promising a tool it explicitly refuses to be.
PRIMARY_CATEGORY = "EDUCATION"
SECONDARY_CATEGORY = "MUSIC"

# 30 characters.
SUBTITLE = "Fold a protein. Hear it fold."

# 100 characters, comma separated, no spaces after commas (they count).
KEYWORDS = ("protein,folding,music,sonification,alphafold,structural biology,"
            "biochemistry,teaching,visionos")

# 170 characters. Changeable without a new build.
PROMOTIONAL_TEXT = (
    "Choose a protein and watch it fold on your device, in real time, while the fold "
    "plays itself as music. Nothing is uploaded. Nothing is precomputed."
)

DESCRIPTION = """\
PhoneFold folds a protein on the device in your hand and turns the trajectory into music. Choose one, watch it collapse out of an extended chain into its structure, and hear the contacts forming as they form.

It is a concert rather than a workbench. Nothing is uploaded, nothing is queued, and nothing is precomputed: the fold happens while you watch it, on your device, and the piece is generated from that fold rather than played over it.

THREE ENGINES, EACH SAYING WHAT IT IS

Simulate. A coarse-grained structure-based model relaxes a named protein from a random coil into its known structure. Real physics, arriving where the prediction says it should.

Morph. A geometric interpolation in torsion space, which keeps bond lengths honest where a straight line through Cartesian space would collapse them.

Generate. Genie 2, a diffusion model, running on the device and inventing a backbone that did not exist before you pressed the button.

Each engine says on screen what it is and is not. None of them is a measurement of how a real protein folds, and the app never implies otherwise.

THE MUSIC

Contacts forming become note onsets. Hydropathy sets pitch, secondary structure sets texture, and how compact the protein has become sets the tempo, so a fold that arrives quickly sounds like one. Five voices, switchable mid-piece. Spatial audio places every note where its residue actually is, so the protein collapses around you on headphones. PhoneFold can appear as a MIDI device so a DAW can record the fold live, and it exports MIDI, mmCIF and 4K film with the music attached.

ON EVERY SCREEN YOU HAVE

iPhone and iPad. The stage, the score and a gallery of twelve proteins, plus any UniProt accession you care to type.

Mac. PhoneFold Studio: multiple windows for two proteins side by side, batch mode that folds a whole FASTA overnight, ProRes and image-sequence export, a CoreMIDI device, and drag-and-drop comparison of a prediction against an experimental structure.

Apple Watch. A transport remote with the Digital Crown scrubbing the timeline, the fold's rhythm on your wrist, a complication, and a Fold of the Day that runs with no phone at all.

Apple Vision Pro. The protein in a volume on your desk, or an immersive concert hall at room scale where you can scale it up until the hydrophobic core closes around you. Pinch a residue to pin its label and solo its note. SharePlay puts a room full of people inside the same fold.

HONEST ABOUT WHAT IT IS

PhoneFold is not a structure predictor and not a molecular dynamics package. The physics is coarse-grained, the generative model is unconditional, and the app tells you which you are watching and what that means. It is for the moment a protein stops being a diagram and becomes a thing that moves.

PRIVACY

PhoneFold collects nothing. No account, no analytics, no advertising, no tracking. The only network request it ever makes is for a structure you ask for by accession.

Open source under the MIT licence.
"""

WHATS_NEW = """\
First release.
"""


SCREENSHOT_PLAN = {
    # Both iPhone slots are filled. App Store Connect dims and locks whichever
    # size it decides to derive from another, so supplying only one leaves the
    # other showing as read-only. APP_IPHONE_65 at 1242x2688 is the pairing an
    # already-accepted app in this account uses, alongside the same iPad type.
    "IOS": [
        ("APP_IPHONE_67", "screenshots/iphone69"),
        ("APP_IPHONE_65", "screenshots/iphone65"),
        ("APP_IPAD_PRO_3GEN_129", "screenshots/ipad13"),
    ],
    "VISION_OS": [("APP_APPLE_VISION_PRO", "screenshots/visionos")],
    # An iOS binary that embeds a watch app must ship a watch screenshot, and
    # App Store Connect only says so at "Add for Review".
    "IOS_WATCH": [("APP_WATCH_SERIES_10", "screenshots/watch")],
    # **No MAC_OS in 1.0, deliberately.** PLAN.md's Mac surface is "PhoneFold
    # Studio", a second product with its own identifier, its own listing and
    # features the phone does not have - batch mode, multi-window, ProRes,
    # structure comparison. The plain PhoneFold target also builds for macOS,
    # but that exists so the stage compiles under two entry points rather than
    # as the Mac product, and shipping it would put a lesser Mac app in the
    # store under the name of the better one. Studio gets its own record.
}


def upload_screenshots(auth: str, app: str) -> None:
    import hashlib
    import urllib.request

    root = Path(__file__).resolve().parent.parent / "assets"

    for version in versions(auth, app):
        platform = version["attributes"].get("platform")
        plan = list(SCREENSHOT_PLAN.get(platform) or [])
        if platform == "IOS":
            plan += SCREENSHOT_PLAN.get("IOS_WATCH") or []
        if not plan:
            continue

        locs = call("GET",
                    f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                    auth=auth)["data"]
        loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
        if not loc:
            print(f"  {platform}: no {LOCALE} localisation")
            continue

        existing = call("GET",
                        f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets",
                        auth=auth)["data"]
        by_type = {e["attributes"]["screenshotDisplayType"]: e["id"] for e in existing}

        for display_type, folder in plan:
            directory = root / folder
            images = sorted(directory.glob("*.png")) if directory.exists() else []
            if not images:
                print(f"  {platform} {display_type}: no captures in {folder}")
                continue

            set_id = by_type.get(display_type)
            if not set_id:
                created = call("POST", "/appScreenshotSets", {
                    "data": {
                        "type": "appScreenshotSets",
                        "attributes": {"screenshotDisplayType": display_type},
                        "relationships": {"appStoreVersionLocalization": {
                            "data": {"type": "appStoreVersionLocalizations",
                                     "id": loc["id"]}}},
                    }
                }, auth=auth)
                set_id = created["data"]["id"]

            have = call("GET", f"/appScreenshotSets/{set_id}/appScreenshots",
                        auth=auth)["data"]
            have_names = {h["attributes"].get("fileName") for h in have}

            for image in images:
                if image.name in have_names:
                    print(f"  {platform} {display_type}: {image.name} already there")
                    continue
                data = image.read_bytes()

                # Phase 1: reserve, and Apple replies with where to PUT it.
                reserved = call("POST", "/appScreenshots", {
                    "data": {
                        "type": "appScreenshots",
                        "attributes": {"fileSize": len(data), "fileName": image.name},
                        "relationships": {"appScreenshotSet": {
                            "data": {"type": "appScreenshotSets", "id": set_id}}},
                    }
                }, auth=auth)["data"]

                # Phase 2: run every upload operation. Large files come back as
                # several ranged PUTs, so this is a loop rather than one call.
                for op in reserved["attributes"]["uploadOperations"]:
                    chunk = data[op["offset"]:op["offset"] + op["length"]]
                    request = urllib.request.Request(
                        op["url"], method=op["method"], data=chunk)
                    for header in op.get("requestHeaders", []):
                        request.add_header(header["name"], header["value"])
                    urllib.request.urlopen(request, timeout=180).read()

                # Phase 3: commit with the checksum, or it stays in limbo and
                # never appears in the listing.
                call("PATCH", f"/appScreenshots/{reserved['id']}", {
                    "data": {
                        "type": "appScreenshots", "id": reserved["id"],
                        "attributes": {"uploaded": True,
                                       "sourceFileChecksum": hashlib.md5(data).hexdigest()},
                    }
                }, auth=auth)
                print(f"  {platform} {display_type}: uploaded {image.name}")

            order_screenshots(auth, set_id)


def order_screenshots(auth: str, set_id: str) -> None:
    """
    Tell the set what order its screenshots go in.

    Uploading is not enough. Until the set's `appScreenshots` relationship is
    PATCHed with an explicit ordering, App Store Connect renders the images
    greyed out and refuses to let you click them, even though the API reports
    every asset as COMPLETE with no errors and no warnings. Nothing in the
    upload response hints at this.
    """
    shots = call("GET", f"/appScreenshotSets/{set_id}/appScreenshots", auth=auth)["data"]
    if not shots:
        return
    ordered = sorted(shots, key=lambda s: s["attributes"].get("fileName") or "")
    call("PATCH", f"/appScreenshotSets/{set_id}/relationships/appScreenshots", {
        "data": [{"type": "appScreenshots", "id": s["id"]} for s in ordered]
    }, auth=auth)
    print(f"    ordered {len(ordered)} screenshots")


EULA_TEXT = """\
PhoneFold is free and open-source software, licensed under the MIT Licence.

Copyright (c) 2026 Marc C. Deller

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Source code: https://github.com/bellcheddar/PhoneFold

BUNDLED THIRD-PARTY COMPONENTS

This app includes a Core ML export of Genie 2 (Apache Licence 2.0, aqlaboratory), trajectories captured from ESMFold (MIT, Meta Platforms), and structures derived from the RCSB PDB (CC0 1.0), the AlphaFold Protein Structure Database and UniProt (CC BY 4.0). Full attribution, including what was changed in the Genie 2 export, is at https://github.com/bellcheddar/PhoneFold/blob/main/THIRD-PARTY.md

SCIENTIFIC USE

PhoneFold shows a simulation or a generative model, not a measurement of how a real protein folds, and it states which on screen for every engine. It is not a structure prediction service, not a molecular dynamics package, not a medical device, and is not intended for diagnostic use.
"""


def set_eula(auth: str, app: str) -> None:
    """
    A custom licence agreement.

    Apple's standard EULA is the default and would be perfectly adequate, but
    this app is MIT-licensed open source that bundles four third-party
    components under three different licences, and the store listing is where
    a user is most likely to look for that.
    """
    territories = [t["id"] for t in
                   call("GET", "/territories?limit=200", auth=auth)["data"]]

    existing = call("GET", f"/apps/{app}/endUserLicenseAgreement", auth=auth).get("data")
    body_attributes = {"agreementText": EULA_TEXT}
    relationships = {
        "app": {"data": {"type": "apps", "id": app}},
        "territories": {"data": [{"type": "territories", "id": t}
                                 for t in territories]},
    }
    if existing:
        call("PATCH", f"/endUserLicenseAgreements/{existing['id']}", {
            "data": {"type": "endUserLicenseAgreements", "id": existing["id"],
                     "attributes": body_attributes,
                     "relationships": {"territories": relationships["territories"]}}
        }, auth=auth)
        print(f"  licence agreement updated ({len(territories)} territories)")
    else:
        call("POST", "/endUserLicenseAgreements", {
            "data": {"type": "endUserLicenseAgreements",
                     "attributes": body_attributes,
                     "relationships": relationships}
        }, auth=auth)
        print(f"  licence agreement set ({len(territories)} territories)")


def attach_builds(auth: str, app: str) -> None:
    """
    Attach each processed build to its platform's version.

    A build cannot be attached while Apple is still processing it: the PATCH
    returns 409. Processing takes ten to thirty minutes, so this is a separate,
    re-runnable step rather than part of the upload.
    """
    by_platform = {}
    for build in call("GET", f"/apps/{app}/builds?limit=20", auth=auth)["data"]:
        if build["attributes"].get("processingState") != "VALID":
            continue
        pre = call("GET", f"/builds/{build['id']}/preReleaseVersion",
                   auth=auth).get("data") or {}
        platform = (pre.get("attributes") or {}).get("platform")
        if platform:
            by_platform.setdefault(platform, build["id"])

    for version in versions(auth, app):
        platform = version["attributes"]["platform"]
        current = call("GET", f"/appStoreVersions/{version['id']}/build",
                       auth=auth).get("data")
        if current:
            print(f"  {platform}: already attached")
            continue
        build_id = by_platform.get(platform)
        if not build_id:
            print(f"  {platform}: no processed build yet")
            continue
        call("PATCH", f"/appStoreVersions/{version['id']}", {
            "data": {"type": "appStoreVersions", "id": version["id"],
                     "relationships": {"build": {"data": {"type": "builds",
                                                          "id": build_id}}}}
        }, auth=auth)
        print(f"  {platform}: attached")


def reorder_all_screenshots(auth: str, app: str) -> None:
    """Re-apply the display order to every existing set."""
    for version in versions(auth, app):
        platform = version["attributes"]["platform"]
        for loc in call("GET",
                        f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                        auth=auth)["data"]:
            for st in call("GET",
                           f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets",
                           auth=auth)["data"]:
                print(f"  {platform} {st['attributes']['screenshotDisplayType']}:")
                order_screenshots(auth, st["id"])


# App Review contact. Reused across every platform version.
REVIEW_CONTACT = {
    "contactFirstName": "Marc",
    "contactLastName": "Deller",
    "contactPhone": "13023586093",
    "contactEmail": "marc@marcdeller.com",
    "demoAccountRequired": False,
}

REVIEW_NOTES = """\
PhoneFold folds a protein on the device and turns the trajectory into music. Everything runs locally. There is no account, no sign-in and no server: the only network request the app can make is fetching one predicted structure from the AlphaFold database, and only when the reviewer types an accession.

TO TRY IT
1. Launch the app. It opens on Trp-cage TC5b and begins folding immediately - the stage is empty for a few seconds while the physics runs, which is the app working rather than failing.
2. Wait for the fold to arrive, then press play. The music is generated from the fold; it is not a soundtrack.
3. Tap any protein in the gallery at the bottom to fold a different one. Villin HP36 and the WW domain are quick; lysozyme takes longer.
4. Tap Generate to have the device invent a backbone that did not exist before, with Genie 2 running locally.
5. Optionally type a UniProt accession (for example P69905) in the field at the bottom. This is the one action that uses the network.

WHAT IT IS NOT
PhoneFold is not a structure prediction service and not a medical or diagnostic tool. The folding it shows is a coarse-grained simulation or a generative model, and the app states which on screen for every engine. No health claim is made anywhere.

APPLE WATCH
The watch app is a remote for the phone and a standalone Fold of the Day. It runs no inference.

APPLE VISION PRO
The protein appears in a volume, or in an immersive space at room scale.

PRIVACY
Nothing is collected. The privacy policy is at https://bellcheddar.github.io/PhoneFold/privacy.html and the source is at https://github.com/bellcheddar/PhoneFold.
"""


def set_review_details(auth: str, app: str) -> None:
    """
    App Review contact information, per platform version.

    Required before submission and easy to miss, because App Store Connect
    lists it under the version rather than the app: a multiplatform app needs
    it filled in separately for each of iOS, macOS and visionOS.
    """
    for version in versions(auth, app):
        platform = version["attributes"]["platform"]
        existing = call("GET", f"/appStoreVersions/{version['id']}/appStoreReviewDetail",
                        auth=auth).get("data")
        attributes = {**REVIEW_CONTACT, "notes": REVIEW_NOTES}
        if existing:
            call("PATCH", f"/appStoreReviewDetails/{existing['id']}", {
                "data": {"type": "appStoreReviewDetails", "id": existing["id"],
                         "attributes": attributes}
            }, auth=auth)
            print(f"  {platform}: review contact updated")
        else:
            call("POST", "/appStoreReviewDetails", {
                "data": {"type": "appStoreReviewDetails", "attributes": attributes,
                         "relationships": {"appStoreVersion": {
                             "data": {"type": "appStoreVersions", "id": version["id"]}}}}
            }, auth=auth)
            print(f"  {platform}: review contact created")


def set_content_rights(auth: str, app: str) -> None:
    call("PATCH", f"/apps/{app}", {
        "data": {"type": "apps", "id": app,
                 "attributes": {
                     "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}
    }, auth=auth)
    print("  content rights: no third-party content requiring rights")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "all"
    auth = token()
    app = app_id(auth)
    print(f"app {app} ({BUNDLE_ID})")

    steps = {
        "categories": set_categories,
        "appinfo": set_app_info_localisation,
        "versions": set_version_localisations,
        "copyright": set_copyright,
        "pricing": set_free,
        "agerating": set_age_rating,
        "rights": set_content_rights,
        "screenshots": upload_screenshots,
        "eula": set_eula,
        "attach-builds": attach_builds,
        "review": set_review_details,
        "reorder": reorder_all_screenshots,
    }
    if command == "all":
        # Not attach-builds: a build still processing returns 409, and that is
        # a normal state rather than a failure worth printing on every run.
        chosen = {k: v for k, v in steps.items() if k != "attach-builds"}
    else:
        chosen = {command: steps[command]}
    for name, fn in chosen.items():
        try:
            fn(auth, app)
        except Exception as error:
            print(f"  FAILED {name}: {str(error)[:400]}")
