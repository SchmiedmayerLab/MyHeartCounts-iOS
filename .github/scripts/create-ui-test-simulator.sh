#!/bin/bash
#
# This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV must be set}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID must be set}"
: "${UI_TEST_SIMULATOR_DEVICE_TYPE:?UI_TEST_SIMULATOR_DEVICE_TYPE must be set}"

# Without an explicit version, use the iOS version of the selected Xcode's simulator SDK: the newest iOS that Xcode supports.
if [[ -z "${UI_TEST_SIMULATOR_RUNTIME:-}" ]]; then
    UI_TEST_SIMULATOR_RUNTIME="$(xcrun --sdk iphonesimulator --show-sdk-version)"
fi
echo "Using the iOS $UI_TEST_SIMULATOR_RUNTIME simulator runtime"

# Prints the identifier of the installed iOS simulator runtime with the requested version that supports the device type,
# if there is one. Device-specific runtimes (e.g. `iOS-27-2-iPhone19-4`) share the version but only support their own
# device type, and can be listed before the general runtime.
runtime_identifier() {
    xcrun simctl list --json runtimes \
    | jq -r --arg version "$UI_TEST_SIMULATOR_RUNTIME" --arg deviceType "$UI_TEST_SIMULATOR_DEVICE_TYPE" \
        'first(.runtimes[]
            | select(.platform == "iOS" and .version == $version and .isAvailable)
            | select(any(.supportedDeviceTypes[]?; .identifier == $deviceType))
            | .identifier)'
}

runtime="$(runtime_identifier)"
if [[ -z "$runtime" ]]; then
    # Simulator runtimes are installed machine-wide and shared by all Xcode versions, so only a runner's first job downloads it.
    if [[ "$(uname -m)" == arm64 ]]; then
        architecture_variant=arm64
    else
        architecture_variant=universal
    fi
    echo "Downloading the iOS $UI_TEST_SIMULATOR_RUNTIME simulator runtime ($architecture_variant)"
    xcodebuild -downloadPlatform iOS -buildVersion "$UI_TEST_SIMULATOR_RUNTIME" -architectureVariant "$architecture_variant"
    runtime="$(runtime_identifier)"
fi
if [[ -z "$runtime" ]]; then
    echo "::error::The iOS $UI_TEST_SIMULATOR_RUNTIME simulator runtime is not available."
    exit 1
fi

udid="$(xcrun simctl create "MHC UI Tests (run $GITHUB_RUN_ID)" "$UI_TEST_SIMULATOR_DEVICE_TYPE" "$runtime")"
echo "Created simulator $udid ($UI_TEST_SIMULATOR_DEVICE_TYPE, $runtime)"
{
    echo "UI_TEST_SIMULATOR_UDID=$udid"
    echo "UI_TEST_DESTINATION=platform=iOS Simulator,id=$udid"
} >> "$GITHUB_ENV"
