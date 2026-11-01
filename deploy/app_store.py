#!/usr/bin/env python3
#
# This source file is part of the My Heart Counts iOS open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Submits an uploaded build to App Review, for release as soon as it is approved.

Cancels any submission that is still in review, brings the version's metadata and screenshots in line with the
`metadata` and `screenshots` folders (replacing all screenshots of each locale that has a screenshots folder), and,
once App Store Connect has processed the build, attaches it to the version and submits the version for review.
"""

import argparse
import hashlib
import re
import time
from pathlib import Path

import asc
from asc import log, fail

# The metadata files, by the resource and attribute they set.
VERSION_LOCALIZATION_FILES = {
    "description.txt": "description",
    "keywords.txt": "keywords",
    "marketing_url.txt": "marketingUrl",
    "promotional_text.txt": "promotionalText",
    "support_url.txt": "supportUrl",
}
APP_INFO_LOCALIZATION_FILES = {
    "name.txt": "name",
    "subtitle.txt": "subtitle",
    "privacy_url.txt": "privacyPolicyUrl",
}
APP_FILES = {"copyright.txt", "primary_category.txt", "secondary_category.txt"}

# Screenshots are named `<position>_<display type>_<anything>.<png|jpg>`, e.g. `0_APP_IPHONE_67_0.png`.
SCREENSHOT_NAME = re.compile(r"(\d+)_(APP_[A-Z0-9_]+?)_\d+\.(png|jpg)")

IN_PROGRESS_SUBMISSION_STATES = "WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES,CANCELING"
EDITABLE_VERSION_STATES = "PREPARE_FOR_SUBMISSION,READY_FOR_REVIEW,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED,INVALID_BINARY"
EDITABLE_APP_INFO_STATES = {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED", "WAITING_FOR_REVIEW"}

deployment_dir = Path(__file__).parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--version", required=True, help="The build's CFBundleShortVersionString.")
parser.add_argument("--build-number", required=True, help="The build's CFBundleVersion.")
parser.add_argument("--release-notes", required=True, help="The version's \"What's New\" text, for all locales.")
parser.add_argument("--metadata", type=Path, default=deployment_dir / "metadata")
parser.add_argument("--screenshots", type=Path, default=deployment_dir / "screenshots")
args = parser.parse_args()


def read_metadata(directory):
    """Reads the metadata, by locale ("" for the app-wide files), failing on files it doesn't know."""
    metadata = {}
    for path in sorted(directory.rglob("*.txt")):
        locale = "" if path.parent == directory else path.parent.name
        known = APP_FILES if not locale else VERSION_LOCALIZATION_FILES.keys() | APP_INFO_LOCALIZATION_FILES.keys()
        if path.name not in known:
            fail(f"unknown metadata file {path}")
        metadata.setdefault(locale, {})[path.name] = path.read_text().strip()
    return metadata


def read_screenshots(directory):
    """Reads the screenshots, by locale and display type, in the order they should appear in."""
    screenshots = {}
    for locale_dir in sorted(path for path in directory.iterdir() if path.is_dir()):
        by_display_type = {}
        for path in sorted(path for path in locale_dir.iterdir() if not path.name.startswith(".")):
            match = SCREENSHOT_NAME.fullmatch(path.name)
            if not match:
                fail(f"screenshot {path} is not named <position>_<display type>_<number>.<png|jpg>")
            by_display_type.setdefault(match[2], []).append((int(match[1]), path))
        screenshots[locale_dir.name] = {kind: [path for _, path in sorted(paths)] for kind, paths in by_display_type.items()}
    return screenshots


def upsert_localizations(path, resource_type, parent, values_by_locale):
    """Updates the localizations at `path` with the non-empty values, creating the missing ones under `parent`.

    Returns the localizations by locale.
    """
    existing = {localization["attributes"]["locale"]: localization for localization in client.get_all(path)}
    for locale, values in values_by_locale.items():
        values = {key: value for key, value in values.items() if value}
        if locale in existing:
            existing[locale] = client.update(existing[locale], values)
        else:
            existing[locale] = client.create(resource_type, {"locale": locale, **values}, parent)
    return existing


def cancel_in_progress_submissions(app_id):
    filters = {"filter[app]": app_id, "filter[platform]": "IOS", "filter[state]": IN_PROGRESS_SUBMISSION_STATES}
    for submission in client.get_all("/v1/reviewSubmissions", **filters):
        if submission["attributes"]["state"] != "CANCELING":
            log(f"Canceling the review submission {submission['id']}, which is {submission['attributes']['state']}")
            client.update(submission, {"canceled": True})
    # The cancellation takes a moment to go through, and the version stays read-only until it has.
    deadline = time.time() + 15 * 60
    while client.get_all("/v1/reviewSubmissions", **filters):
        if time.time() > deadline:
            fail("the review submission did not get canceled in time")
        log("Waiting for the review submission to be canceled")
        time.sleep(15)


def editable_version(app_id, version, copyright):
    attributes = {"versionString": version, "releaseType": "AFTER_APPROVAL"}
    if copyright:
        attributes["copyright"] = copyright
    versions = client.get(f"/v1/apps/{app_id}/appStoreVersions", **{
        "filter[platform]": "IOS",
        "filter[appVersionState]": EDITABLE_VERSION_STATES,
    })
    if versions:
        return client.update(versions[0], attributes)
    log(f"Creating version {version}")
    return client.create("appStoreVersions", {"platform": "IOS", **attributes}, {"app": ("apps", app_id)})


def editable_app_info(app_id):
    for app_info in client.get_all(f"/v1/apps/{app_id}/appInfos"):
        if app_info["attributes"]["state"] in EDITABLE_APP_INFO_STATES:
            return app_info
    fail("found no editable app info")


def replace_screenshots(localization, screenshots_by_display_type):
    sets = client.get_all(f"/v1/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets")
    for screenshot_set in sets:
        for screenshot in client.get_all(f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots"):
            client.delete(screenshot)
    sets = {screenshot_set["attributes"]["screenshotDisplayType"]: screenshot_set for screenshot_set in sets}
    uploaded = []
    for display_type, paths in screenshots_by_display_type.items():
        screenshot_set = sets.get(display_type) or client.create(
            "appScreenshotSets",
            {"screenshotDisplayType": display_type},
            {"appStoreVersionLocalization": ("appStoreVersionLocalizations", localization["id"])}
        )
        # Screenshots appear in the order they were uploaded in.
        for path in paths:
            log(f"Uploading {path}")
            data = path.read_bytes()
            screenshot = client.create(
                "appScreenshots",
                {"fileName": path.name, "fileSize": len(data)},
                {"appScreenshotSet": ("appScreenshotSets", screenshot_set["id"])}
            )
            for operation in screenshot["attributes"]["uploadOperations"]:
                chunk = data[operation["offset"]:operation["offset"] + operation["length"]]
                headers = {header["name"]: header["value"] for header in operation["requestHeaders"]}
                asc.send(operation["method"], operation["url"], chunk, lambda: headers)
            uploaded.append(client.update(screenshot, {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}))
    return uploaded


def wait_for_screenshots(screenshots, timeout=15 * 60):
    deadline = time.time() + timeout
    for screenshot in screenshots:
        while True:
            state = client.request("GET", f"/v1/appScreenshots/{screenshot['id']}")["data"]["attributes"]["assetDeliveryState"]
            if state["state"] == "COMPLETE":
                break
            if state["state"] == "FAILED" or time.time() > deadline:
                fail(f"processing the screenshot {screenshot['attributes']['fileName']} failed: {state}")
            time.sleep(5)


def submit_for_review(app_id, version):
    drafts = client.get_all("/v1/reviewSubmissions", **{"filter[app]": app_id, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"})
    if drafts:
        submission = drafts[0]
        items = client.get_all(f"/v1/reviewSubmissions/{submission['id']}/items", include="appStoreVersion")
        item_versions = [(item["relationships"].get("appStoreVersion", {}).get("data") or {}).get("id") for item in items]
        if any(item_version != version["id"] for item_version in item_versions):
            fail("the unsubmitted review submission in App Store Connect contains other items; remove them first")
    else:
        submission = client.create("reviewSubmissions", {"platform": "IOS"}, {"app": ("apps", app_id)})
        item_versions = []
    if version["id"] not in item_versions:
        client.create("reviewSubmissionItems", relationships={
            "reviewSubmission": ("reviewSubmissions", submission["id"]),
            "appStoreVersion": ("appStoreVersions", version["id"]),
        })
    # The version needs a moment to become ready for review.
    for _ in range(10):
        if client.request("GET", f"/v1/appStoreVersions/{version['id']}")["data"]["attributes"]["appVersionState"] == "READY_FOR_REVIEW":
            break
        time.sleep(15)
    client.update(submission, {"submitted": True})


metadata = read_metadata(args.metadata)
screenshots = read_screenshots(args.screenshots)
app_wide = metadata.pop("", {})
missing_screenshot_locales = screenshots.keys() - metadata.keys()
if missing_screenshot_locales:
    fail(f"screenshots for locales without metadata: {', '.join(sorted(missing_screenshot_locales))}")

client = asc.Client()
app_id = client.app_id()

cancel_in_progress_submissions(app_id)
version = editable_version(app_id, args.version, app_wide.get("copyright.txt"))

log("Updating the metadata")
app_info = editable_app_info(app_id)
categories = {"primaryCategory": "primary_category.txt", "secondaryCategory": "secondary_category.txt"}
client.update(app_info, relationships={
    relationship: ("appCategories", app_wide[file]) for relationship, file in categories.items() if app_wide.get(file)
})
upsert_localizations(
    f"/v1/appInfos/{app_info['id']}/appInfoLocalizations",
    "appInfoLocalizations",
    {"appInfo": ("appInfos", app_info["id"])},
    {
        locale: {attribute: values.get(file) for file, attribute in APP_INFO_LOCALIZATION_FILES.items()}
        for locale, values in metadata.items()
    }
)
version_localizations = upsert_localizations(
    f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
    "appStoreVersionLocalizations",
    {"appStoreVersion": ("appStoreVersions", version["id"])},
    {
        locale: {"whatsNew": args.release_notes, **{attribute: values.get(file) for file, attribute in VERSION_LOCALIZATION_FILES.items()}}
        for locale, values in metadata.items()
    }
)

uploaded_screenshots = []
for locale, screenshots_by_display_type in screenshots.items():
    log(f"Replacing the {locale} screenshots")
    uploaded_screenshots += replace_screenshots(version_localizations[locale], screenshots_by_display_type)
wait_for_screenshots(uploaded_screenshots)

build = client.wait_for_build(app_id, args.version, args.build_number)
log(f"Submitting version {args.version} ({args.build_number}) for review")
client.request("PATCH", f"/v1/appStoreVersions/{version['id']}/relationships/build", {"data": {"type": "builds", "id": build["id"]}})
submit_for_review(app_id, version)
