#!/bin/bash
#
# This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

: "${UI_TEST_DESTINATION:?UI_TEST_DESTINATION must be set}"
: "${UI_TEST_PRODUCTS_PATH:?UI_TEST_PRODUCTS_PATH must be set}"

TEST_PLAN_PATH='MyHeartCountsUITests/MyHeartCounts UI Tests.xctestplan'
MAX_ATTEMPTS=5

# Xcode 27.2 writes a random subset of the statically linked Swift package targets into the .xctestrun's
# CodeCoverageBuildableInfos, even when nothing changed between two builds. A coverage target that is missing from that
# list is silently left out of every shard's coverage report (this is what made MyHeartCountsShared's UI-test coverage
# randomly drop to 0 on Codecov), so we rebuild until every coverage target of the test plan is present.
missing_coverage_targets() {
    local xctestrun
    xctestrun="$(find "$UI_TEST_PRODUCTS_PATH/Tests" -maxdepth 2 -name '*.xctestrun' -print -quit)"
    plutil -extract CodeCoverageBuildableInfos json -o - "$xctestrun" \
    | jq -r --slurpfile plan "$TEST_PLAN_PATH" '
        ($plan[0].defaultOptions.codeCoverage | if type == "object" then [.targets[]?.name] else [] end)
        - [.[] | select(.IncludeInReport) | .Name | sub("\\.(app|appex|xctest|framework)$"; "")]
        | .[]'
}

mkdir -p "$(dirname "$UI_TEST_PRODUCTS_PATH")"
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    # xcodebuild doesn't replace an existing test products path; it writes a timestamped bundle inside it instead.
    rm -rf "${UI_TEST_PRODUCTS_PATH:?}"
    xcodebuild \
        -scheme MyHeartCounts \
        -configuration Debug \
        -destination "$UI_TEST_DESTINATION" \
        -testPlan 'MyHeartCounts UI Tests' \
        -enableCodeCoverage YES \
        -testProductsPath "$UI_TEST_PRODUCTS_PATH" \
        -derivedDataPath .derivedData \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        build-for-testing \
    | xcbeautify

    missing="$(missing_coverage_targets)"
    if [[ -z "$missing" ]]; then
        exit 0
    fi
    echo "::warning::Build $attempt of $MAX_ATTEMPTS: the xctestrun lacks coverage targets: ${missing//$'\n'/, }"
done
echo "::warning::UI test coverage will be incomplete; no build produced every coverage target of the test plan."
