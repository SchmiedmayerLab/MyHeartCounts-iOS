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

mkdir -p "$(dirname "$UI_TEST_PRODUCTS_PATH")"
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
