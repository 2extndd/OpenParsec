#!/usr/bin/env bash

set -euo pipefail

OPENPARSEC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENPARSEC_XCODE_APP="${OPENPARSEC_XCODE_APP:-/Applications/Xcode.app}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "${OPENPARSEC_XCODE_APP}/Contents/Developer" ]]; then
    export DEVELOPER_DIR="${OPENPARSEC_XCODE_APP}/Contents/Developer"
  else
    selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "${selected_developer_dir}" && -x "${selected_developer_dir}/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="${selected_developer_dir}"
    else
      printf '%s\n' "[openparsec-env] error: full Xcode is not available" >&2
      printf '%s\n' "[openparsec-env] set OPENPARSEC_XCODE_APP or DEVELOPER_DIR to a valid Xcode installation" >&2
      exit 1
    fi
  fi
fi

if [[ ! -x "${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
  printf '%s\n' "[openparsec-env] error: ${DEVELOPER_DIR} is not a full Xcode developer directory" >&2
  exit 1
fi

openparsec_print_xcode_env() {
  local xcode_version
  local ios_sdk_version

  xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  ios_sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"

  printf '%s\n' "[openparsec-env] root=${OPENPARSEC_ROOT}"
  printf '%s\n' "[openparsec-env] developer_dir=${DEVELOPER_DIR}"
  printf '%s\n' "[openparsec-env] xcode=${xcode_version}"
  printf '%s\n' "[openparsec-env] iphoneos_sdk=${ios_sdk_version}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  openparsec_print_xcode_env
fi
