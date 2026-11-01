#!/usr/bin/env python3
#
# This source file is part of the My Heart Counts iOS open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Distributes an uploaded build to a TestFlight group, once App Store Connect has processed it.

Sets the build's "What to Test" notes, has TestFlight notify the testers once the build is available to them, and, for
an external group, submits the build to Beta App Review, in place of any other build of the version that is still
waiting for review.
"""

import argparse

import asc
from asc import log, fail

# The blocks of code points that emoji are made of; App Store Connect rejects "What to Test" notes that contain any.
EMOJI_RANGES = [
    (0x200D, 0x200D), (0x20E3, 0x20E3), (0x2300, 0x23FF), (0x2600, 0x27BF), (0x2B00, 0x2BFF), (0xFE0F, 0xFE0F),
    (0x1F000, 0x1FAFF), (0xE0020, 0xE007F),
]
MAX_CHANGELOG_BYTES = 4000

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--version", required=True, help="The build's CFBundleShortVersionString.")
parser.add_argument("--build-number", required=True, help="The build's CFBundleVersion.")
parser.add_argument("--group", required=True, help="The name of the TestFlight group to distribute the build to.")
parser.add_argument("--changelog", required=True, help="The build's \"What to Test\" notes.")
args = parser.parse_args()


def sanitized(changelog):
    """Removes what App Store Connect doesn't accept in "What to Test" notes: emoji, `<`, and anything past 4000 bytes."""
    changelog = "".join(
        character for character in changelog
        if character != "<" and not any(low <= ord(character) <= high for low, high in EMOJI_RANGES)
    )
    if len(changelog.encode()) > MAX_CHANGELOG_BYTES:
        changelog = changelog.encode()[:MAX_CHANGELOG_BYTES - 3].decode(errors="ignore") + "..."
    return changelog


client = asc.Client()
app_id = client.app_id()

# Look up the group before waiting for the build, so that a typo fails right away.
groups = [group for group in client.get_all("/v1/betaGroups", **{"filter[app]": app_id, "filter[name]": args.group})
          if group["attributes"]["name"] == args.group]
if not groups:
    fail(f"no TestFlight group named \"{args.group}\"")
group = groups[0]
is_internal_group = group["attributes"]["isInternalGroup"]

build = client.wait_for_build(app_id, args.version, args.build_number)

log("Setting the \"What to Test\" notes")
changelog = sanitized(args.changelog)
localizations = client.get_all(f"/v1/builds/{build['id']}/betaBuildLocalizations")
for localization in localizations:
    client.update(localization, {"whatsNew": changelog})
if not any(localization["attributes"]["locale"] == "en-US" for localization in localizations):
    client.create("betaBuildLocalizations", {"locale": "en-US", "whatsNew": changelog}, {"build": ("builds", build["id"])})

beta_detail = client.get(f"/v1/builds/{build['id']}/buildBetaDetail")
client.update(beta_detail, {"autoNotifyEnabled": True})

if not is_internal_group:
    waiting_builds = client.get_all("/v1/builds", **{
        "filter[app]": app_id,
        "filter[preReleaseVersion.version]": args.version,
        "filter[betaAppReviewSubmission.betaReviewState]": "WAITING_FOR_REVIEW,IN_REVIEW",
        "filter[expired]": "false",
    })
    for waiting_build in waiting_builds:
        if waiting_build["id"] != build["id"]:
            log(f"Expiring build {waiting_build['attributes']['version']}, which is still waiting for Beta App Review")
            client.update(waiting_build, {"expired": True})
    if beta_detail["attributes"]["externalBuildState"] == "READY_FOR_BETA_SUBMISSION":
        log("Submitting the build to Beta App Review")
        client.create("betaAppReviewSubmissions", relationships={"build": ("builds", build["id"])})
    else:
        log(f"Not submitting the build to Beta App Review, its state is {beta_detail['attributes']['externalBuildState']}")

if is_internal_group and group["attributes"]["hasAccessToAllBuilds"]:
    log(f"\"{args.group}\" gets every build automatically")
else:
    log(f"Adding the build to \"{args.group}\"")
    client.request("POST", f"/v1/builds/{build['id']}/relationships/betaGroups", {"data": [{"type": "betaGroups", "id": group["id"]}]})
