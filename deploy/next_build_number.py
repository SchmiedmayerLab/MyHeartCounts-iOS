#!/usr/bin/env python3
#
# This source file is part of the My Heart Counts iOS open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Prints the build number to use for the next upload: one more than the highest build number uploaded so far."""

import asc

client = asc.Client()
builds = client.get("/v1/builds", **{
    "filter[app]": client.app_id(),
    "filter[preReleaseVersion.platform]": "IOS",
    "sort": "-uploadedDate",
    "fields[builds]": "version",
    "limit": 200,
})
print(max((int(build["attributes"]["version"]) for build in builds), default=0) + 1)
