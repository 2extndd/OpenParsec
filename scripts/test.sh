#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./xcode-env.sh
source "${SCRIPT_DIR}/xcode-env.sh"

PROJECT="${OPENPARSEC_PROJECT:-${OPENPARSEC_ROOT}/OpenParsec.xcodeproj}"
SCHEME="${OPENPARSEC_TEST_SCHEME:-OpenParsec}"
SIMULATOR_NAME="${OPENPARSEC_SIMULATOR_NAME:-iPad (A16)}"
BUILD_ROOT="${OPENPARSEC_ROOT}/.build"
RESULTS_DIR="${RESULTS_DIR:-${BUILD_ROOT}/results}"
RUN_ID="${OPENPARSEC_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}}"
RUN_DIR="${OPENPARSEC_TEST_RUN_DIR:-${RESULTS_DIR}/runs/${RUN_ID}}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${RUN_DIR}/DerivedData}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-${RUN_DIR}/OpenParsec-tests.xcresult}"
TEST_LOG_PATH="${TEST_LOG_PATH:-${RUN_DIR}/OpenParsec-tests.log}"
VALIDATE_ONLY="${OPENPARSEC_TEST_VALIDATE_ONLY:-0}"

fail_setup() {
  printf '%s\n' "[openparsec-test] result=failed phase=setup reason=$1" >&2
  exit 2
}

canonical_directory() {
  local path="$1"
  mkdir -p "${path}"
  (cd "${path}" && pwd -P)
}

canonical_file_path() {
  local path="$1"
  local parent
  parent="$(canonical_directory "$(dirname "${path}")")"
  printf '%s/%s\n' "${parent}" "$(basename "${path}")"
}

require_clean_absolute_path() {
  local candidate="$1"
  local label="$2"
  [[ "${candidate}" == /* ]] || fail_setup "non_absolute_${label}_path"
  case "/${candidate}/" in
    *"/../"*|*"/./"*) fail_setup "non_canonical_${label}_path" ;;
  esac
}

require_strict_child_path() {
  local root="$1"
  local candidate="$2"
  local label="$3"
  case "${candidate}" in
    "${root}"/*) ;;
    *) fail_setup "unsafe_${label}_path" ;;
  esac
}

reject_recursive_delete_overlap() {
  local candidate="$1"
  shift
  local protected
  for protected in "$@"; do
    case "${protected}" in
      "${candidate}"|"${candidate}"/*) fail_setup "protected_result_bundle_path" ;;
    esac
  done
}

require_suffix() {
  local path="$1"
  local suffix="$2"
  local label="$3"
  [[ "${path}" == *"${suffix}" ]] || fail_setup "invalid_${label}_suffix"
}

validate_test_summary() {
  local summary="$1"
  local counts result total passed failed skipped
  if ! counts="$(
    printf '%s' "${summary}" |
      jq -er '[.result // "unknown", .totalTestCount // 0, .passedTests // 0, .failedTests // 0, .skippedTests // 0] | @tsv'
  )"; then
    printf '%s\n' "[openparsec-test] result=failed phase=contract reason=invalid_summary" >&2
    return 3
  fi
  IFS=$'\t' read -r result total passed failed skipped <<<"${counts}"
  printf '%s\n' "[openparsec-test] tests=${total} passed=${passed} failed=${failed} skipped=${skipped}"

  if [[ "${total}" -le 0 ]]; then
    printf '%s\n' "[openparsec-test] result=failed phase=contract reason=zero_tests" >&2
    return 3
  fi
  if [[ "${failed}" -ne 0 ]]; then
    printf '%s\n' "[openparsec-test] result=failed phase=contract reason=failed_tests count=${failed}" >&2
    return 3
  fi
  if [[ "${skipped}" -ne 0 ]]; then
    printf '%s\n' "[openparsec-test] result=failed phase=contract reason=skipped_tests count=${skipped}" >&2
    return 3
  fi
  if [[ "${passed}" -ne "${total}" || "${result}" != "Passed" ]]; then
    printf '%s\n' "[openparsec-test] result=failed phase=contract reason=count_mismatch result=${result}" >&2
    return 3
  fi
  printf '%s\n' "[openparsec-test] result=passed phase=contract"
}

SIMULATOR_LOCK_DIR=""

release_simulator_lock() {
  [[ -n "${SIMULATOR_LOCK_DIR}" ]] || return 0
  rm -f -- "${SIMULATOR_LOCK_DIR}/owner.pid"
  rmdir "${SIMULATOR_LOCK_DIR}" 2>/dev/null || true
  SIMULATOR_LOCK_DIR=""
}

acquire_simulator_lock() {
  local simulator_id="$1"
  local lock_root timeout deadline owner lock_mtime owner_grace
  lock_root="$(canonical_directory "${BUILD_ROOT}/locks")"
  timeout="${OPENPARSEC_TEST_LOCK_TIMEOUT:-1800}"
  deadline=$(( $(date +%s) + timeout ))
  SIMULATOR_LOCK_DIR="${lock_root}/simulator-${simulator_id}.lock"

  while ! mkdir "${SIMULATOR_LOCK_DIR}" 2>/dev/null; do
    owner=""
    if [[ -f "${SIMULATOR_LOCK_DIR}/owner.pid" ]]; then
      owner="$(<"${SIMULATOR_LOCK_DIR}/owner.pid")"
    fi
    if [[ -n "${owner}" ]] && ! kill -0 "${owner}" 2>/dev/null; then
      rm -f -- "${SIMULATOR_LOCK_DIR}/owner.pid"
      rmdir "${SIMULATOR_LOCK_DIR}" 2>/dev/null || true
      continue
    fi
    if [[ -z "${owner}" && -d "${SIMULATOR_LOCK_DIR}" ]]; then
      lock_mtime="$(stat -f '%m' "${SIMULATOR_LOCK_DIR}" 2>/dev/null || printf '0')"
      owner_grace="${OPENPARSEC_TEST_OWNER_GRACE_SECONDS:-5}"
      if [[ $(( $(date +%s) - lock_mtime )) -ge ${owner_grace} ]]; then
        rmdir "${SIMULATOR_LOCK_DIR}" 2>/dev/null || true
        continue
      fi
    fi
    if [[ $(date +%s) -ge ${deadline} ]]; then
      printf '%s\n' "[openparsec-test] result=failed phase=lock reason=timeout simulator=${simulator_id}" >&2
      exit 4
    fi
    sleep 1
  done

  printf '%s\n' "$$" > "${SIMULATOR_LOCK_DIR}/owner.pid"
  trap release_simulator_lock EXIT
  trap 'release_simulator_lock; exit 130' INT
  trap 'release_simulator_lock; exit 143' TERM
  printf '%s\n' "[openparsec-test] lock=acquired simulator=${simulator_id}"
}

require_clean_absolute_path "${RESULTS_DIR}" "results"
require_clean_absolute_path "${RUN_DIR}" "run"
require_clean_absolute_path "${DERIVED_DATA_PATH}" "derived_data"
require_clean_absolute_path "${RESULT_BUNDLE_PATH}" "result_bundle"
require_clean_absolute_path "${TEST_LOG_PATH}" "test_log"
require_strict_child_path "${BUILD_ROOT}" "${RESULTS_DIR}" "results"
require_strict_child_path "${RESULTS_DIR}" "${RUN_DIR}" "run"
require_strict_child_path "${BUILD_ROOT}" "${DERIVED_DATA_PATH}" "derived_data"
require_strict_child_path "${RESULTS_DIR}" "${RESULT_BUNDLE_PATH}" "result_bundle"
require_strict_child_path "${RESULTS_DIR}" "${TEST_LOG_PATH}" "test_log"
require_suffix "${RESULT_BUNDLE_PATH}" ".xcresult" "result_bundle"
require_suffix "${TEST_LOG_PATH}" ".log" "test_log"
reject_recursive_delete_overlap \
  "${RESULT_BUNDLE_PATH}" \
  "${RESULTS_DIR}" "${RUN_DIR}" "${DERIVED_DATA_PATH}" "${TEST_LOG_PATH}"
for protected in "${RESULTS_DIR}" "${RUN_DIR}" "${DERIVED_DATA_PATH}"; do
  [[ "${TEST_LOG_PATH}" != "${protected}" ]] || fail_setup "protected_test_log_path"
done

BUILD_ROOT="$(canonical_directory "${BUILD_ROOT}")"
RESULTS_DIR="$(canonical_directory "${RESULTS_DIR}")"
require_strict_child_path "${BUILD_ROOT}" "${RESULTS_DIR}" "results"
RUN_DIR="$(canonical_directory "${RUN_DIR}")"
require_strict_child_path "${RESULTS_DIR}" "${RUN_DIR}" "run"
DERIVED_DATA_PATH="$(canonical_directory "${DERIVED_DATA_PATH}")"
require_strict_child_path "${BUILD_ROOT}" "${DERIVED_DATA_PATH}" "derived_data"
RESULT_BUNDLE_PATH="$(canonical_file_path "${RESULT_BUNDLE_PATH}")"
require_strict_child_path "${RESULTS_DIR}" "${RESULT_BUNDLE_PATH}" "result_bundle"
TEST_LOG_PATH="$(canonical_file_path "${TEST_LOG_PATH}")"
require_strict_child_path "${RESULTS_DIR}" "${TEST_LOG_PATH}" "test_log"
reject_recursive_delete_overlap \
  "${RESULT_BUNDLE_PATH}" \
  "${RESULTS_DIR}" "${RUN_DIR}" "${DERIVED_DATA_PATH}" "${TEST_LOG_PATH}"
for protected in "${RESULTS_DIR}" "${RUN_DIR}" "${DERIVED_DATA_PATH}"; do
  [[ "${TEST_LOG_PATH}" != "${protected}" ]] || fail_setup "protected_test_log_path"
done

if [[ -n "${OPENPARSEC_TEST_SUMMARY_JSON:-}" ]]; then
  validate_test_summary "${OPENPARSEC_TEST_SUMMARY_JSON}"
  exit $?
fi

runtime_id="$(
  xcrun simctl list runtimes -j |
    jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version) | last.identifier // empty'
)"

if [[ -z "${runtime_id}" ]]; then
  printf '%s\n' "[openparsec-test] result=failed phase=destination reason=no_available_ios_runtime" >&2
  printf '%s\n' "[openparsec-test] install one with: xcodebuild -downloadPlatform iOS" >&2
  exit 2
fi

available_devices="$(xcrun simctl list devices available -j)"
simulator_id="${OPENPARSEC_SIMULATOR_ID:-}"
if [[ -n "${simulator_id}" ]]; then
  validated_id="$(
    printf '%s' "${available_devices}" |
      jq -r --arg runtime "${runtime_id}" --arg id "${simulator_id}" \
        '.devices[$runtime][]? | select(.udid == $id and .isAvailable) | .udid' |
      head -n 1
  )"
  [[ -n "${validated_id}" ]] || {
    printf '%s\n' "[openparsec-test] result=failed phase=destination reason=invalid_simulator_id runtime=${runtime_id}" >&2
    exit 2
  }
else
  simulator_id="$(
    printf '%s' "${available_devices}" |
      jq -r --arg runtime "${runtime_id}" --arg name "${SIMULATOR_NAME}" \
        '.devices[$runtime][]? | select(.name == $name and .isAvailable) | .udid' |
      head -n 1
  )"
fi

if [[ -z "${simulator_id}" ]]; then
  device_type_id="$(
    xcrun simctl list devicetypes -j |
      jq -r --arg name "${SIMULATOR_NAME}" '.devicetypes[] | select(.name == $name) | .identifier' |
      head -n 1
  )"
  if [[ -z "${device_type_id}" ]]; then
    printf '%s\n' "[openparsec-test] result=failed phase=destination reason=unknown_device_type name=${SIMULATOR_NAME}" >&2
    exit 2
  fi
  simulator_id="$(xcrun simctl create "OpenParsec Test ${SIMULATOR_NAME}" "${device_type_id}" "${runtime_id}")"
fi

printf '%s\n' "[openparsec-test] phase=setup"
printf '%s\n' "[openparsec-test] run_id=${RUN_ID}"
printf '%s\n' "[openparsec-test] run_dir=${RUN_DIR}"
printf '%s\n' "[openparsec-test] runtime=${runtime_id}"
printf '%s\n' "[openparsec-test] simulator=${simulator_id}"
printf '%s\n' "[openparsec-test] derived_data=${DERIVED_DATA_PATH}"
printf '%s\n' "[openparsec-test] result_bundle=${RESULT_BUNDLE_PATH}"
printf '%s\n' "[openparsec-test] log=${TEST_LOG_PATH}"

lock_validation_seconds="${OPENPARSEC_TEST_VALIDATE_LOCK_SECONDS:-0}"
if [[ "${VALIDATE_ONLY}" == "1" && "${lock_validation_seconds}" == "0" ]]; then
  printf '%s\n' "[openparsec-test] result=passed phase=validation"
  exit 0
fi

acquire_simulator_lock "${simulator_id}"
if [[ "${VALIDATE_ONLY}" == "1" ]]; then
  sleep "${lock_validation_seconds}"
  printf '%s\n' "[openparsec-test] result=passed phase=lock-validation"
  exit 0
fi

simulator_state="$(
  printf '%s' "${available_devices}" |
    jq -r --arg runtime "${runtime_id}" --arg id "${simulator_id}" \
      '.devices[$runtime][]? | select(.udid == $id) | .state // empty'
)"
if [[ "${simulator_state}" != "Booted" ]]; then
  xcrun simctl boot "${simulator_id}"
fi
xcrun simctl bootstatus "${simulator_id}" -b

if [[ -e "${RESULT_BUNDLE_PATH}" || -L "${RESULT_BUNDLE_PATH}" ]]; then
  rm -rf -- "${RESULT_BUNDLE_PATH}"
fi
rm -f -- "${TEST_LOG_PATH}"

openparsec_print_xcode_env
printf '%s\n' "[openparsec-test] phase=test scheme=${SCHEME}"

set +e
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_id}" \
  -destination-timeout 120 \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -resultBundlePath "${RESULT_BUNDLE_PATH}" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  test 2>&1 | tee "${TEST_LOG_PATH}"
status=${PIPESTATUS[0]}
set -e

summary_contract_status=3
if [[ -d "${RESULT_BUNDLE_PATH}" ]]; then
  summary="$(xcrun xcresulttool get test-results summary --path "${RESULT_BUNDLE_PATH}" --compact 2>/dev/null || true)"
  if [[ -n "${summary}" ]]; then
    set +e
    validate_test_summary "${summary}"
    summary_contract_status=$?
    set -e
  else
    printf '%s\n' "[openparsec-test] result=failed phase=contract reason=missing_summary" >&2
  fi
else
  printf '%s\n' "[openparsec-test] result=failed phase=contract reason=missing_result_bundle" >&2
fi

if [[ "${status}" -ne 0 ]]; then
  if grep -q "Unable to find a destination matching" "${TEST_LOG_PATH}"; then
    runtime_architectures="$(
      xcrun simctl list runtimes -j |
        jq -r --arg id "${runtime_id}" '.runtimes[] | select(.identifier == $id) | .supportedArchitectures | join(",")'
    )"
    excluded_architectures="$(
      xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -sdk iphonesimulator -showBuildSettings 2>/dev/null |
        awk -F ' = ' '/^[[:space:]]*EXCLUDED_ARCHS =/ { print $2; exit }'
    )"
    printf '%s\n' \
      "[openparsec-test] result=failed phase=destination reason=no_matching_simulator_architecture runtime_architectures=${runtime_architectures:-unknown} excluded_architectures=${excluded_architectures:-none}" >&2
  fi
  printf '%s\n' "[openparsec-test] result=failed phase=test exit=${status}" >&2
  exit "${status}"
fi

if [[ "${summary_contract_status}" -ne 0 ]]; then
  exit "${summary_contract_status}"
fi

ln -sfn "${RESULT_BUNDLE_PATH}" "${RESULTS_DIR}/OpenParsec-tests-latest.xcresult"
ln -sfn "${TEST_LOG_PATH}" "${RESULTS_DIR}/OpenParsec-tests-latest.log"
printf '%s\n' "[openparsec-test] result=passed phase=test"
