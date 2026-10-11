#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="${OPENPARSEC_COVERAGE_ROOT:-${DEFAULT_ROOT}}"

entries=(
  "connect|OpenParsecUITests/OpenParsecUITests.swift|testSuccessfulFakeConnectionReachesProductionSessionView"
  "media-readiness|OpenParsecUITests/OpenParsecUITests.swift|testBlackFrameScenarioExposesMissingFirstFrame"
  "media-recovery|OpenParsecUITests/OpenParsecUITests.swift|testMediaWatchdogReconnectsSamePeerWithoutTap"
  "background-reconnect|OpenParsecUITests/OpenParsecUITests.swift|testForcedBackgroundExpiryReconnectsWithoutConnectTap"
  "pointer-modes|OpenParsecUITests/OpenParsecUITests.swift|testPointerModesExposeNativeAndCapturedOwnership"
  "keyboard-lifecycle|OpenParsecUITests/OpenParsecUITests.swift|testBackgroundReleasesHeldKeyboardState"
  "mac-shortcuts|OpenParsecTests/ParsecClientTypesTests.swift|testMacShortcutCatalogClassifiesNativeMacroAndUnavailableRoutes"
  "windows-shortcuts|OpenParsecUITests/OpenParsecUITests.swift|testWindowsRawMacroExecutesInCommandAsControlMode"
  "gamepad|OpenParsecUITests/OpenParsecUITests.swift|testGamepadInputReleasesWithoutStuckButtonThroughProductionPath"
  "settings|OpenParsecTests/ParsecClientTypesTests.swift|testSettingsContractMatchesPersistedKeysTwoWay"
  "concurrency|OpenParsecTests/ParsecClientTypesTests.swift|testCParsecRepeatedConnectCyclesAdvanceGenerationAndReleaseAllInput"
  "network-recovery|OpenParsecUITests/OpenParsecUITests.swift|testActiveTransportDropReconnectsAutomaticallyWithoutSecondTap"
  "network-exhaustion|OpenParsecUITests/OpenParsecUITests.swift|testActiveTransportReconnectExhaustionStopsAtReplacementGeneration"
  "network-cancellation|OpenParsecUITests/OpenParsecUITests.swift|testCancellingPendingTransportReconnectPreventsAnotherAttempt"
  "api-auth|OpenParsecUITests/OpenParsecUITests.swift|testExpiredAuthShowsActionableMessageAndReturnsToSignIn"
  "failure-diagnostics|OpenParsecUITests/OpenParsecUITests.swift|testRendererFailurePreservesRawCodeInTerminalDiagnostic"
)

missing=0
for entry in "${entries[@]}"; do
  IFS='|' read -r category relative_path symbol <<<"${entry}"
  path="${ROOT}/${relative_path}"
  if [[ ! -f "${path}" ]]; then
    printf '%s\n' "[openparsec-coverage] category=${category} result=missing reason=file path=${relative_path}" >&2
    missing=$((missing + 1))
    continue
  fi
  if ! rg -q "func[[:space:]]+${symbol}[[:space:]]*\\(" "${path}"; then
    printf '%s\n' "[openparsec-coverage] category=${category} result=missing reason=test symbol=${symbol}" >&2
    missing=$((missing + 1))
    continue
  fi
  printf '%s\n' "[openparsec-coverage] category=${category} result=covered test=${symbol}"
done

if [[ "${missing}" -ne 0 ]]; then
  printf '%s\n' "[openparsec-coverage] result=failed categories=${#entries[@]} missing=${missing}" >&2
  exit 1
fi

printf '%s\n' "[openparsec-coverage] result=passed categories=${#entries[@]} missing=0"
