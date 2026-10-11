#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./xcode-env.sh
source "${SCRIPT_DIR}/xcode-env.sh"

PROJECT="${OPENPARSEC_PROJECT:-${OPENPARSEC_ROOT}/OpenParsec.xcodeproj}"
SCHEME="${OPENPARSEC_SCHEME:-OpenParsec}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${OPENPARSEC_ROOT}/.build/DerivedData}"
RESULTS_DIR="${RESULTS_DIR:-${OPENPARSEC_ROOT}/.build/results}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-${RESULTS_DIR}/OpenParsec-build.xcresult}"

mkdir -p "${DERIVED_DATA_PATH}" "${RESULTS_DIR}"
rm -rf "${RESULT_BUNDLE_PATH}"

openparsec_print_xcode_env
printf '%s\n' "[openparsec-build] phase=build"
printf '%s\n' "[openparsec-build] project=${PROJECT}"
printf '%s\n' "[openparsec-build] scheme=${SCHEME}"
printf '%s\n' "[openparsec-build] configuration=${CONFIGURATION}"
printf '%s\n' "[openparsec-build] destination=generic/platform=iOS"
printf '%s\n' "[openparsec-build] derived_data=${DERIVED_DATA_PATH}"
printf '%s\n' "[openparsec-build] result_bundle=${RESULT_BUNDLE_PATH}"

if xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=iOS" \
  -sdk iphoneos \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -resultBundlePath "${RESULT_BUNDLE_PATH}" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build; then
  printf '%s\n' "[openparsec-build] result=passed phase=build"
else
  status=$?
  printf '%s\n' "[openparsec-build] result=failed phase=build exit=${status}" >&2
  exit "${status}"
fi
