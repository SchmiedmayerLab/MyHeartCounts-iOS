#
# This source file is part of the My Heart Counts iOS open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""A minimal App Store Connect API client, shared by the deployment scripts.

Uses only the Python standard library (3.9, as bundled with Xcode), plus `openssl` to sign the API tokens.
Reads the API key from the `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and
`APP_STORE_CONNECT_API_KEY_BASE64` environment variables.

API reference: https://developer.apple.com/documentation/appstoreconnectapi
"""

import atexit
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE_ID = "edu.stanford.MyHeartCounts"
API_URL = "https://api.appstoreconnect.apple.com"
RETRIED_STATUS_CODES = {429, 500, 502, 503, 504}


def log(message):
    print(message, file=sys.stderr, flush=True)


def fail(message):
    log(f"error: {message}")
    sys.exit(1)


def _base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def _relationships(relationships):
    return {name: {"data": {"type": kind, "id": identifier}} for name, (kind, identifier) in relationships.items()}


def _raw_signature(der):
    # openssl emits a DER `SEQUENCE { r INTEGER, s INTEGER }`, but ES256 tokens carry the two 32 byte integers concatenated.
    # A P-256 signature is at most 72 bytes long, so all lengths are in the short form.
    offset = 2
    raw = b""
    for _ in range(2):
        length = der[offset + 1]
        raw += der[offset + 2:offset + 2 + length].lstrip(b"\0").rjust(32, b"\0")
        offset += 2 + length
    return raw


class Client:
    def __init__(self):
        try:
            self.key_id = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
            self.issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
            key = base64.b64decode(os.environ["APP_STORE_CONNECT_API_KEY_BASE64"])
        except KeyError as error:
            fail(f"missing environment variable {error}")
        descriptor, self.key_path = tempfile.mkstemp(suffix=".p8")
        atexit.register(os.remove, self.key_path)
        with os.fdopen(descriptor, "wb") as file:
            file.write(key)
        self._token = None
        self._token_date = 0

    def token(self):
        # Tokens may be valid for at most 20 minutes; waiting for a build to process takes longer than that.
        if time.time() - self._token_date > 10 * 60:
            now = int(time.time())
            header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
            payload = {"iss": self.issuer_id, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
            signing_input = _base64url(json.dumps(header).encode()) + b"." + _base64url(json.dumps(payload).encode())
            signature = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", self.key_path],
                input=signing_input, capture_output=True, check=True
            ).stdout
            self._token = (signing_input + b"." + _base64url(_raw_signature(signature))).decode()
            self._token_date = now
        return self._token

    def request(self, method, path, body=None, params=None):
        """Sends a request to the API, and returns the decoded response body (or `None` for an empty one)."""
        url = path if "://" in path else API_URL + path  # pagination links are absolute
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        response = send(method, url, data, lambda: {"Authorization": f"Bearer {self.token()}", "Content-Type": "application/json"})
        return json.loads(response) if response else None

    def get(self, path, **params):
        return self.request("GET", path, params=params)["data"]

    def get_all(self, path, **params):
        """Fetches all pages of a collection."""
        page = self.request("GET", path, params={"limit": 200, **params})
        items = page["data"]
        while page["links"].get("next"):
            page = self.request("GET", page["links"]["next"])
            items += page["data"]
        return items

    def create(self, resource_type, attributes=None, relationships=None):
        data = {"type": resource_type}
        if attributes:
            data["attributes"] = attributes
        if relationships:
            data["relationships"] = _relationships(relationships)
        return self.request("POST", f"/v1/{resource_type}", {"data": data})["data"]

    def update(self, resource, attributes=None, relationships=None):
        data = {"type": resource["type"], "id": resource["id"]}
        if attributes:
            data["attributes"] = attributes
        if relationships:
            data["relationships"] = _relationships(relationships)
        return self.request("PATCH", f"/v1/{resource['type']}/{resource['id']}", {"data": data})["data"]

    def delete(self, resource):
        self.request("DELETE", f"/v1/{resource['type']}/{resource['id']}")

    def app_id(self):
        apps = [app for app in self.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID}) if app["attributes"]["bundleId"] == BUNDLE_ID]
        if not apps:
            fail(f"no app with the bundle identifier {BUNDLE_ID}")
        return apps[0]["id"]

    def wait_for_build(self, app_id, version, build_number, timeout=2 * 60 * 60):
        """Waits until App Store Connect has processed the uploaded build, and returns it."""
        log(f"Waiting for build {version} ({build_number}) to finish processing")
        deadline = time.time() + timeout
        while time.time() < deadline:
            builds = self.get("/v1/builds", **{
                "filter[app]": app_id,
                "filter[version]": build_number,
                "filter[preReleaseVersion.version]": version,
                "filter[preReleaseVersion.platform]": "IOS",
            })
            # The build only shows up a few minutes after the upload finished.
            state = builds[0]["attributes"]["processingState"] if builds else "NOT_FOUND"
            if state == "VALID":
                return builds[0]
            if state in {"FAILED", "INVALID"}:
                fail(f"processing build {version} ({build_number}) failed: {state}")
            log(f"Build state: {state}")
            time.sleep(30)
        fail(f"build {version} ({build_number}) did not finish processing in time")


def send(method, url, data=None, headers=None, attempts=6):
    """Sends an HTTP request, retrying rate-limited requests, server errors and network errors with a growing delay.

    `headers` is a function, so that every attempt can use a fresh token.
    """
    for attempt in range(attempts):
        request = urllib.request.Request(url, data=data, method=method, headers=headers() if headers else {})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors="replace")
            if error.code not in RETRIED_STATUS_CODES or attempt == attempts - 1:
                fail(f"{method} {url} failed with HTTP {error.code}:\n{body}")
            log(f"{method} {url} failed with HTTP {error.code}; retrying")
        except OSError as error:  # URLError, and socket timeouts while reading the response
            if attempt == attempts - 1:
                fail(f"{method} {url} failed: {error}")
            log(f"{method} {url} failed: {error}; retrying")
        time.sleep(5 * 2 ** attempt)
