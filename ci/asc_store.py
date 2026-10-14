#!/usr/bin/env python3
"""Fill in the App Store listing and TestFlight info from store/ – as drafts. NEVER submits anything for review.

Uses the App Store Connect API key from the repository secrets (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8) and
the BUNDLE_ID variable. Every section is independent: a failure is reported and the rest continues.
"""
import hashlib
import json
import os
import sys
import time
from pathlib import Path

import jwt
import requests

ROOT = Path(__file__).resolve().parent.parent
META = json.loads((ROOT / "store" / "metadata.json").read_text())
SHOTS = sorted((ROOT / "store" / "screenshots" / META["locale"]).glob("*.png"))
API = "https://api.appstoreconnect.apple.com"
problems = []


def note(msg):
    print(f"::notice title=App Store Connect::{msg}")


def warn(msg):
    problems.append(msg)
    print(f"::warning title=App Store Connect::{msg}")


class ASC:
    def __init__(self):
        self.key_id = os.environ["ASC_KEY_ID"]
        self.issuer = os.environ["ASC_ISSUER_ID"]
        self.key = os.environ["ASC_KEY_P8"]
        self._t, self._exp = None, 0

    def token(self):
        now = int(time.time())
        if not self._t or now > self._exp - 60:
            self._exp = now + 1100
            self._t = jwt.encode({"iss": self.issuer, "iat": now, "exp": self._exp, "aud": "appstoreconnect-v1"},
                                 self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})
        return self._t

    def call(self, method, path, body=None, params=None, ok=(200, 201, 204)):
        r = requests.request(method, API + path, json=body, params=params, timeout=120,
                             headers={"Authorization": f"Bearer {self.token()}"})
        data = r.json() if r.content and "json" in r.headers.get("content-type", "") else {}
        if r.status_code not in ok:
            errs = "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}" for e in data.get("errors", [])) or r.text[:300]
            raise RuntimeError(f"{method} {path} → {r.status_code}: {errs}")
        return data

    def get(self, path, **params):
        return self.call("GET", path, params=params or None)


def section(name):
    def wrap(fn):
        def run(*a, **k):
            try:
                fn(*a, **k)
            except Exception as exc:
                warn(f"{name}: {exc}")
        return run
    return wrap


asc = ASC()
bundle = os.environ["BUNDLE_ID"]
apps = [a for a in asc.get("/v1/apps", **{"filter[bundleId]": bundle})["data"] if a["attributes"]["bundleId"] == bundle]
if not apps:
    print(f"::error::No App Store Connect app with bundle ID {bundle}")
    sys.exit(1)
app = apps[0]
APP = app["id"]
LOCALE = META["locale"]
note(f"App: {app['attributes'].get('name')} ({bundle}), primary language {app['attributes'].get('primaryLocale')}")


def upsert_localization(list_path, patch_type, create_type, parent_rel, parent_type, parent_id, attrs):
    """PATCH the localization for LOCALE, or create it."""
    items = asc.get(list_path)["data"]
    loc = next((i for i in items if i["attributes"].get("locale") == LOCALE), None)
    if loc:
        asc.call("PATCH", f"/v1/{patch_type}/{loc['id']}", {"data": {"type": patch_type, "id": loc["id"], "attributes": attrs}})
        return loc["id"]
    d = asc.call("POST", f"/v1/{create_type}", {"data": {"type": create_type, "attributes": {"locale": LOCALE, **attrs},
                 "relationships": {parent_rel: {"data": {"type": parent_type, "id": parent_id}}}}})
    return d["data"]["id"]


# ------------------------------------------------------------------ App information
@section("App information")
def app_info():
    infos = asc.get(f"/v1/apps/{APP}/appInfos")["data"]
    editable = [i for i in infos if i["attributes"].get("appStoreState", i["attributes"].get("state")) not in
                ("READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_INFO")] or infos
    info = editable[0]
    upsert_localization(f"/v1/appInfos/{info['id']}/appInfoLocalizations", "appInfoLocalizations", "appInfoLocalizations",
                        "appInfo", "appInfos", info["id"],
                        {"name": META["name"], "subtitle": META["subtitle"], "privacyPolicyUrl": META["privacy_policy_url"]})
    note(f"Name '{META['name']}', subtitle and privacy policy URL set")
    asc.call("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": META["category"]}}}}})
    note(f"Category: {META['category']}")
    age = asc.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    none = "NONE"
    attrs = {k: none for k in ("alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
                               "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity",
                               "sexualContentOrNudity", "horrorOrFearThemes", "matureOrSuggestiveThemes",
                               "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic")}
    attrs.update({k: False for k in ("advertising", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat",
                                     "parentalControls", "ageAssurance", "socialMedia", "unrestrictedWebAccess",
                                     "userGeneratedContent")})
    try:
        asc.call("PATCH", f"/v1/ageRatingDeclarations/{age['id']}", {"data": {"type": "ageRatingDeclarations", "id": age["id"], "attributes": attrs}})
    except RuntimeError as exc:   # some keys may not exist in this API version – retry with the classic set
        warn(f"Age rating (full set) not accepted, retrying basic set: {exc}")
        basic = {k: v for k, v in attrs.items() if v == none} | {"gambling": False, "unrestrictedWebAccess": False}
        asc.call("PATCH", f"/v1/ageRatingDeclarations/{age['id']}", {"data": {"type": "ageRatingDeclarations", "id": age["id"], "attributes": basic}})
    note("Age rating answers: none of the content categories (rating 4+)")


# ------------------------------------------------------------------ App Store version 1.0
def get_version():
    vs = asc.get(f"/v1/apps/{APP}/appStoreVersions", **{"filter[platform]": "IOS", "limit": 20})["data"]
    edit_states = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY")
    for v in vs:
        st = v["attributes"].get("appVersionState") or v["attributes"].get("appStoreState")
        if st in edit_states:
            return v
    d = asc.call("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions",
                 "attributes": {"platform": "IOS", "versionString": "1.0"},
                 "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    return d["data"]


VERSION = None


@section("Version 1.0 texts")
def version_texts():
    global VERSION
    VERSION = get_version()
    vid = VERSION["id"]
    asc.call("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid,
             "attributes": {"copyright": META["copyright"], "releaseType": "MANUAL"}}})
    upsert_localization(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                        "appStoreVersionLocalizations", "appStoreVersion", "appStoreVersions", vid,
                        {"description": META["description"], "keywords": META["keywords"],
                         "promotionalText": META["promotional_text"], "supportUrl": META["support_url"],
                         "marketingUrl": META["marketing_url"]})
    note(f"Version {VERSION['attributes'].get('versionString')}: description, keywords, promotional text, URLs, "
         "copyright set; release = manually after approval")


@section("Screenshots")
def screenshots():
    if not VERSION:
        raise RuntimeError("no version")
    locs = asc.get(f"/v1/appStoreVersions/{VERSION['id']}/appStoreVersionLocalizations")["data"]
    loc = next(i for i in locs if i["attributes"]["locale"] == LOCALE)
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
    sset = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_IPHONE_67"), None)
    if not sset:
        sset = asc.call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                        "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
    for old in asc.get(f"/v1/appScreenshotSets/{sset['id']}/appScreenshots")["data"]:
        asc.call("DELETE", f"/v1/appScreenshots/{old['id']}")
    for f in SHOTS:
        data = f.read_bytes()
        shot = asc.call("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
                        "attributes": {"fileName": f.name, "fileSize": len(data)},
                        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sset["id"]}}}}})["data"]
        for op in shot["attributes"]["uploadOperations"]:
            part = data[op["offset"]:op["offset"] + op["length"]]
            hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            r = requests.request(op["method"], op["url"], data=part, headers=hdrs, timeout=300)
            r.raise_for_status()
        asc.call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
                 "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    time.sleep(20)
    states = [s["attributes"].get("assetDeliveryState", {}).get("state")
              for s in asc.get(f"/v1/appScreenshotSets/{sset['id']}/appScreenshots")["data"]]
    note(f"{len(SHOTS)} iPhone 6.9\" screenshots uploaded (processing: {', '.join(str(s) for s in states)})")


@section("App Review information")
def review_info():
    if not VERSION:
        raise RuntimeError("no version")
    r = META["review"]
    attrs = {"contactFirstName": r["contact_first_name"], "contactLastName": r["contact_last_name"],
             "contactEmail": r["contact_email"], "demoAccountRequired": False, "notes": r["notes"]}
    if r.get("contact_phone"):
        attrs["contactPhone"] = r["contact_phone"]
    try:
        d = asc.get(f"/v1/appStoreVersions/{VERSION['id']}/appStoreReviewDetail")["data"]
    except RuntimeError:
        d = None
    if d:
        asc.call("PATCH", f"/v1/appStoreReviewDetails/{d['id']}", {"data": {"type": "appStoreReviewDetails", "id": d["id"], "attributes": attrs}})
    else:
        asc.call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                 "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": VERSION["id"]}}}}})
    note("App Review contact + notes set (phone: " + ("set" if r.get("contact_phone") else "EMPTY – add it yourself") + ")")


LATEST_BUILD = None


@section("Build")
def attach_build():
    global LATEST_BUILD
    builds = asc.get("/v1/builds", **{"filter[app]": APP, "sort": "-uploadedDate", "limit": 10})["data"]
    valid = [b for b in builds if b["attributes"].get("processingState") == "VALID" and not b["attributes"].get("expired")]
    if not valid:
        raise RuntimeError("no processed build yet")
    LATEST_BUILD = valid[0]
    if VERSION:
        asc.call("PATCH", f"/v1/appStoreVersions/{VERSION['id']}/relationships/build",
                 {"data": {"type": "builds", "id": LATEST_BUILD["id"]}})
        note(f"Build {LATEST_BUILD['attributes'].get('version')} selected for version 1.0 (not submitted)")


# ------------------------------------------------------------------ TestFlight
@section("TestFlight test information")
def testflight():
    t = META["testflight"]
    upsert_localization(f"/v1/apps/{APP}/betaAppLocalizations", "betaAppLocalizations", "betaAppLocalizations",
                        "app", "apps", APP,
                        {"description": t["description"], "feedbackEmail": t["feedback_email"],
                         "marketingUrl": META["marketing_url"], "privacyPolicyUrl": META["privacy_policy_url"]})
    d = asc.get(f"/v1/apps/{APP}/betaAppReviewDetail")["data"]
    r = META["review"]
    attrs = {"contactFirstName": r["contact_first_name"], "contactLastName": r["contact_last_name"],
             "contactEmail": r["contact_email"], "demoAccountRequired": False, "notes": r["notes"]}
    if r.get("contact_phone"):
        attrs["contactPhone"] = r["contact_phone"]
    asc.call("PATCH", f"/v1/betaAppReviewDetails/{d['id']}", {"data": {"type": "betaAppReviewDetails", "id": d["id"], "attributes": attrs}})
    if LATEST_BUILD:
        upsert_localization(f"/v1/builds/{LATEST_BUILD['id']}/betaBuildLocalizations", "betaBuildLocalizations",
                            "betaBuildLocalizations", "build", "builds", LATEST_BUILD["id"], {"whatsNew": t["whats_new"]})
    note("TestFlight: test description, feedback email, review contact and 'What to test' set")


app_info()
version_texts()
screenshots()
review_info()
attach_build()
testflight()
note("Nothing was submitted. Review everything in App Store Connect, then press 'Add for Review' yourself.")
if problems:
    print(f"::warning title=Summary::{len(problems)} section(s) need attention – see warnings above")
