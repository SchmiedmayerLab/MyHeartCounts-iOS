#!/bin/bash
#
# This source file is part of the My Heart Counts iOS open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

# Archives the app, uploads it to App Store Connect, and then either distributes it to a TestFlight group, or, for the
# production environment, submits it to App Review.
#
# Usage: deploy/deploy.sh --environment <development|staging|production> --version <version>
#            [--variant <stanford|imperial>] [--build-number <number>] [--release-notes <text>]
#            [--strip-sensorkit-entitlement]
#
# Without a build number, the build gets the number after the highest one uploaded so far.
# Expects the App Store Connect API key in APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_ISSUER_ID and
# APP_STORE_CONNECT_API_KEY_BASE64, and the signing certificate and provisioning profiles to be installed.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_PLIST="MyHeartCounts/Supporting Files/Info.plist"
WATCH_PLIST="MyHeartCountsWatchApp/Supporting Files/Info.plist"
ENTITLEMENTS="MyHeartCounts/Supporting Files/MyHeartCounts.entitlements"
OUTPUT_DIR=.derivedData/Deployment

environment=""
variant=""
version=""
build_number=""
release_notes=""
strip_sensorkit_entitlement=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment) environment="$2"; shift 2 ;;
        --variant) variant="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --build-number) build_number="$2"; shift 2 ;;
        --release-notes) release_notes="$2"; shift 2 ;;
        --strip-sensorkit-entitlement) strip_sensorkit_entitlement=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 64 ;;
    esac
done
# The deployment workflow passes empty values for inputs that weren't set.
environment="${environment:-staging}"
variant="${variant:-stanford}"
release_notes="${release_notes:-Bug fixes and performance improvements.}"
# The workflow input arrives with the apostrophe escaped.
apostrophe="'"
release_notes="${release_notes//\\u2019/$apostrophe}"

case "$environment" in
    development | staging | production) ;;
    *) echo "Unknown environment '$environment'. Expected 'development', 'staging' or 'production'." >&2; exit 64 ;;
esac
case "$variant" in
    stanford | imperial) ;;
    *) echo "Unknown study variant '$variant'. Expected 'stanford' or 'imperial'." >&2; exit 64 ;;
esac
if [[ -z "$version" ]]; then
    echo "Missing --version." >&2
    exit 64
fi
if [[ "$variant" == imperial && "$environment" == production ]]; then
    echo "Imperial builds are TestFlight-only." >&2
    exit 64
fi
: "${APP_STORE_CONNECT_API_KEY_ID:?}" "${APP_STORE_CONNECT_ISSUER_ID:?}" "${APP_STORE_CONNECT_API_KEY_BASE64:?}"

# The build edits the Info.plists and the entitlements; put them back afterwards, whether it succeeds or not.
work_dir="$(mktemp -d)"
cp "$APP_PLIST" "$work_dir/App-Info.plist"
cp "$WATCH_PLIST" "$work_dir/Watch-Info.plist"
cp "$ENTITLEMENTS" "$work_dir/MyHeartCounts.entitlements"
restore() {
    cp "$work_dir/App-Info.plist" "$APP_PLIST"
    cp "$work_dir/Watch-Info.plist" "$WATCH_PLIST"
    cp "$work_dir/MyHeartCounts.entitlements" "$ENTITLEMENTS"
    rm -rf "$work_dir"
}
trap restore EXIT

current_version="$(plutil -extract CFBundleShortVersionString raw "$APP_PLIST")"
if [[ "$(printf '%s\n' "$current_version" "$version" | sort -V | tail -n 1)" == "$current_version" ]]; then
    [[ "$version" == "$current_version" ]] || echo "Keeping version $current_version, since $version is lower."
    version="$current_version"
else
    # The watch app's version has to match the iOS app's.
    plutil -replace CFBundleShortVersionString -string "$version" "$APP_PLIST"
    plutil -replace CFBundleShortVersionString -string "$version" "$WATCH_PLIST"
fi

if [[ -z "$build_number" ]]; then
    build_number="$(python3 deploy/next_build_number.py)"
fi

if [[ "$strip_sensorkit_entitlement" == true ]]; then
    echo "Stripping the SensorKit entitlement"
    plutil -remove 'com\.apple\.developer\.sensorkit\.reader\.allow' "$ENTITLEMENTS"
fi
# See `FeatureFlags.forcedStudyVariant`.
if [[ "$variant" == imperial ]]; then
    plutil -replace MHCForcedStudyVariant -string imperial "$APP_PLIST"
else
    plutil -remove MHCForcedStudyVariant "$APP_PLIST" 2>/dev/null || true
fi

echo "Building $variant version $version ($build_number) for $environment"
rm -rf "$OUTPUT_DIR"
xcrun xcodebuild archive \
    -project MyHeartCounts.xcodeproj \
    -scheme MyHeartCounts \
    -destination generic/platform=iOS \
    -archivePath "$OUTPUT_DIR/MyHeartCounts.xcarchive" \
    -derivedDataPath .derivedData \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -quiet \
    CURRENT_PROJECT_VERSION="$build_number"
xcrun xcodebuild -exportArchive \
    -archivePath "$OUTPUT_DIR/MyHeartCounts.xcarchive" \
    -exportPath "$OUTPUT_DIR" \
    -exportOptionsPlist deploy/ExportOptions.plist \
    -quiet

echo "Uploading the build"
printf '%s' "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$work_dir/AuthKey.p8"
xcrun altool --upload-package "$OUTPUT_DIR/MyHeartCounts.ipa" \
    --api-key "$APP_STORE_CONNECT_API_KEY_ID" \
    --api-issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --p8-file-path "$work_dir/AuthKey.p8"

if [[ "$environment" == production ]]; then
    python3 deploy/app_store.py --version "$version" --build-number "$build_number" --release-notes "$release_notes"
else
    changelog="$(git log -1 --pretty=%B)"
    if [[ "$variant" == imperial ]]; then
        group="External Testers (Imperial)"
        changelog="[UK] $changelog"
    elif [[ "$environment" == development ]]; then
        group="Development"
    else
        group="External Testers"
    fi
    python3 deploy/testflight.py --version "$version" --build-number "$build_number" --group "$group" --changelog "$changelog"
fi
