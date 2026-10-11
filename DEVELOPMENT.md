# OpenParsec Development

## Supported local toolchain

The repository resolves Xcode without changing the machine-wide `xcode-select` value.

Current verified baseline:

- Xcode 26.3
- iOS and iPadOS SDK 26.2 or newer compatible SDK
- ParsecSDK submodule commit `bb336699`

Override the Xcode application when needed:

```bash
OPENPARSEC_XCODE_APP=/Applications/Xcode.app scripts/xcode-env.sh
```

## Bootstrap

Initialize the pinned ParsecSDK framework after cloning:

```bash
git submodule update --init --recursive
```

Confirm that the framework contains its binary and headers:

```bash
git submodule status
file Frameworks/ParsecSDK.framework/ParsecSDK
```

## Unsigned local build

A paid Apple Developer account is not required for an unsigned generic-device build:

```bash
scripts/build.sh
```

The script writes local artifacts under `.build/`:

- `.build/DerivedData` — Xcode derived data
- `.build/results/OpenParsec-build.xcresult` — build result bundle

Useful overrides:

```bash
CONFIGURATION=Release scripts/build.sh
DERIVED_DATA_PATH=/tmp/OpenParsecDerivedData scripts/build.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build.sh
```

The build script prints the selected Xcode, SDK, destination, derived-data path, result-bundle path, phase, and exit result. It never prints signing credentials.

## Test targets

The project contains three shared schemes:

- `OpenParsec` — application build plus all test bundles in its Test action
- `OpenParsecTests` — unit-test scheme
- `OpenParsecUITests` — UI-test scheme

Compile the application and both test bundles without signing or a connected device:

```bash
source scripts/xcode-env.sh
xcodebuild \
  -project OpenParsec.xcodeproj \
  -scheme OpenParsec \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -derivedDataPath "$PWD/.build/TestTargets" \
  -resultBundlePath "$PWD/.build/results/build-for-testing.xcresult" \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Run both suites on the deterministic iPad Simulator destination:

```bash
scripts/test.sh
```

The runner selects the latest installed iOS runtime and an `iPad (A16)` within that exact runtime, boots it, and disables parallel execution. Every invocation writes isolated evidence under `.build/results/runs/<run-id>/`:

- `OpenParsec-tests.xcresult`
- `OpenParsec-tests.log`
- `DerivedData/`

After a successful contract check, `.build/results/OpenParsec-tests-latest.xcresult` and `.build/results/OpenParsec-tests-latest.log` point to that preserved run. Concurrent runs never delete or overwrite each other's evidence. Caller-provided paths are accepted only beneath the project `.build` root with `.xcresult` or `.log` suffixes as appropriate.

The command fails when xcodebuild fails, the result bundle or summary is missing, zero tests run, any test fails, any test is skipped, or passed/total counts disagree. Override the destination with `OPENPARSEC_SIMULATOR_ID` or `OPENPARSEC_SIMULATOR_NAME`; an explicit ID must belong to the selected runtime. Use `OPENPARSEC_TEST_VALIDATE_ONLY=1 scripts/test.sh` to validate paths and destination selection without running tests.

Validate the regression coverage contract separately:

```bash
scripts/verify-regression-coverage.sh
```

The machine-checkable matrix currently requires these concrete scenarios:

| Contract | Required test |
|---|---|
| Connect | `testSuccessfulFakeConnectionReachesProductionSessionView` |
| Media readiness | `testBlackFrameScenarioExposesMissingFirstFrame` |
| Media recovery | `testMediaWatchdogReconnectsSamePeerWithoutTap` |
| Background reconnect | `testForcedBackgroundExpiryReconnectsWithoutConnectTap` |
| Pointer modes | `testPointerModesExposeNativeAndCapturedOwnership` |
| Keyboard lifecycle | `testBackgroundReleasesHeldKeyboardState` |
| macOS shortcuts | `testMacShortcutCatalogClassifiesNativeMacroAndUnavailableRoutes` |
| Windows shortcuts | `testWindowsRawMacroExecutesInCommandAsControlMode` |
| Gamepad | `testGamepadInputReleasesWithoutStuckButtonThroughProductionPath` |
| Settings | `testSettingsContractMatchesPersistedKeysTwoWay` |
| Concurrency | `testCParsecRepeatedConnectCyclesAdvanceGenerationAndReleaseAllInput` |
| Network recovery | `testActiveTransportDropReconnectsAutomaticallyWithoutSecondTap` |
| Network exhaustion | `testActiveTransportReconnectExhaustionStopsAtReplacementGeneration` |
| Network cancellation | `testCancellingPendingTransportReconnectPreventsAnotherAttempt` |
| Expired auth | `testExpiredAuthShowsActionableMessageAndReturnsToSignIn` |
| Failure diagnostics | `testRendererFailurePreservesRawCodeInTerminalDiagnostic` |

OpenParsec selects adapters by build environment:

- iOS device builds compile `ParsecSDKBridge`, link the real ParsecSDK only for `sdk=iphoneos*`, and embed the framework through the device-only build phase.
- iOS Simulator builds compile `FakeParsecService`, do not link or embed ParsecSDK, and run natively on arm64.

The fake supports deterministic `success`, `timeout`, `blackFrame`, `audioStall`, `reconnect`, `mediaRecovery`, `reconnectExhaustion`, `rendererFailure`, `transportRecovery`, `transportReconnectExhaustion`, and `transportReconnectPending` scenarios. UI tests launch them with `--ui-testing --fake-scenario=<scenario>` and drive the production MainView and ParsecView route. The explicit `--ui-testing` argument is required to bypass keychain and network host discovery; normal application launches never select this bootstrap.

## Session state and diagnostics

`CParsec.sessionSnapshot` is the only application-domain session status surface. Do not derive a second state machine from SwiftUI flags, `ParsecBackgroundManager` booleans, SDK status values, or fake events.

The snapshot exposes:

- a generation that increments for every initial connect, reconnect, or reconfiguration attempt;
- a sequence that increments for every accepted transition;
- adapter and connect intent;
- transport status;
- video and audio readiness;
- explicit disconnect reason;
- the latest redacted failure.

The phases are `idle`, `connecting`, `waiting-for-media`, `waiting-for-first-frame`, `waiting-for-audio`, `interactive`, `background`, `background-grace`, `reconnecting`, `failed`, and `disconnected`. Status or media observations carrying an older generation are rejected. Unchanged polling results are deduplicated and do not advance the sequence or emit another log line.

Each accepted transition emits one unified log record under subsystem `com.openparsec.client` and category `session`. Stream Simulator records with:

```bash
source scripts/xcode-env.sh
xcrun simctl spawn booted log stream \
  --level info \
  --style compact \
  --predicate 'subsystem == "com.openparsec.client" AND category == "session"'
```

For a physical iPad, select the device in Console.app and apply the same subsystem and category filters. A digest with the same phase, generation, sequence, transport, media, adapter, reason, and last-failure fields is shown in the in-session metrics overlay. UI tests read the same snapshots through `openparsec.session.state` and `openparsec.session.diagnostics`.

The latest failure is stored under `openparsec.session.last-failure.v1` in app preferences. Its JSON contains only `rawCode`, `stage`, `adapter`, `generation`, `sequence`, and `timestamp`. Peer IDs, Parsec session IDs, credentials, auth tokens, and keyboard content must never enter the snapshot, log, or persisted record.

## Concurrency and resource safety

The client has one lifecycle generation at the facade boundary. `CParsec` mints it through `ParsecSessionTracker`; duplicate initial connects are rejected without creating another generation. The poll loops in the real SDK bridge also carry a generation token and stop when that token changes, so a reconnect cannot leave an older poll loop consuming the active client.

`ParsecGetBuffer` ownership is paired at the bridge boundary. A non-nil buffer is recorded as acquired, freed exactly once through a `defer`, and recorded as released. A nil result returns before decoding and before freeing. The content-free `openparsec.concurrency.state` diagnostic exposes generation, held input, outstanding buffers, active scheduled timers, active observers, and accepted connect-cycle count. At rest, input, buffers, timers, and observers must all be zero.

Background grace and reconnect delays are the only scheduled timer resources. They are added to the ledger only after the scheduler accepts them and removed when the task is taken for cancellation or completion. The current diagnostics view uses scoped Combine publishers rather than persistent notification observers, so its active observer count remains zero. Mouse, keyboard, gamepad, cursor, and audio ownership stays behind their existing locks and release paths; disconnect, backgrounding, and reconnect release held input before the next generation begins.

Simulator tests prove the pure ledger and repeated fake-adapter cycles. Physical iPad UAT remains required for real SDK poll timing, audio/cursor resource churn, and repeated device connect/disconnect stress.

## Background grace and automatic reconnect

`ParsecBackgroundManager` is the only background-recovery coordinator. Scene, PiP, fake-adapter, and real-SDK paths report through it; they must not directly maintain reconnect booleans or infer callback identity from the latest session snapshot.

The recovery states are:

- `idle`: no background recovery is pending;
- `grace`: one finite UIKit background assertion and one cancellable grace timer protect the current generation;
- `reconnect-pending`: grace expired or transport became unusable, and the saved peer requires foreground recovery;
- `reconnect-scheduled`: exactly one cancellable foreground reconnect callback is scheduled.

A quick app switch cancels the grace timer and assertion, resumes the existing adapter, and preserves the generation. PiP protects the live stream only after AVKit confirms `willStart`; its asynchronous startup retries run under provisional grace. Confirmed PiP start cancels that grace, while PiP start failure or stop while backgrounded opens or continues grace. Grace or UIKit assertion expiry claims the exact generation, disconnects it once, and marks the same peer for recovery. Foreground recovery calls `CParsec.connect(savedPeerID, intent: .reconnect)` directly; it never waits for the host list or network discovery. A successful reconnect advances the generation and returns recovery state to `idle`. Immediate or polled reconnect failure returns to `reconnect-pending` without an unbounded retry loop.

Every timer, assertion, reconnect, connection, and PiP callback is bound to a generation and monotonic token or controller identity. Stale callbacks are rejected. Explicit user disconnect and reconfiguration cancel grace and reconnect resources rather than scheduling recovery.

`ParsecBackgroundManager.recoverySnapshot` exposes only state, generation, and token. Its digest and `background-recovery` OSLog category never contain peer IDs, session IDs, credentials, or tokens from authentication. UI tests additionally expose:

- `openparsec.session.generation`;
- `openparsec.recovery.state`;
- `openparsec.recovery.diagnostics`.

Lifecycle UI tests may use `--disable-pip`, `--background-grace=<seconds>`, and `--background-reconnect-delay=<seconds>`, but these overrides are accepted only with `--ui-testing` in a DEBUG Simulator build. Device and release builds always keep PiP enabled, use a 20-second grace period, and use a 0.5-second reconnect delay.

`ParsecClientConnect` is asynchronous. Its `PARSEC_OK` return means only that the attempt was accepted; `CParsec.connect` must publish app-domain `.connecting` and may advance to `.ok` only when a generation-matched `ParsecClientGetStatus` poll reports a healthy transport. Publishing initiation success as readiness races replacement setup against the SDK: physical evidence captured `ParsecClientSetDimensions == PARSEC_NOT_RUNNING` even though the app snapshot already claimed `.ok`.

Replacement generations require one deterministic host-config refresh after real transport `.ok`. `ParsecView` claims the current generation through `ParsecGenerationRequestGate`, sends `.getVideoConfig` and `.getAdapterInfo` exactly once, and lets the existing case-11/case-12 handlers restore the saved display and confirm output. Do not substitute viewport resets or host-resolution guesses: physical diagnostics showed stable UIKit/GLK geometry, a 2421×1668 drawable, and a matching OpenGL viewport while readiness was the failed boundary.

## Network and session resilience

Active-session transport loss is handled by `ParsecTransportRecoveryMonitor`, a pure generation-aware policy. One failed poll is ignored and a successful poll resets the streak. Five consecutive failures request one same-peer reconnect through `ParsecBackgroundManager`; the monitor never creates timers or calls the adapter itself. A replacement generation that fails before becoming interactive is terminal, so recovery cannot form a reconnect loop. A replacement that becomes interactive completes the recovery episode, and a later independent drop receives a new single-reconnect budget.

`ParsecBackgroundManager.schedulePendingReconnect()` is the only active-session scheduling entry point. It atomically changes `reconnect-pending` to `reconnect-scheduled`, so foreground callbacks and transport recovery cannot create duplicate timers. Explicit Cancel calls `disableAutoReconnect()` before disconnecting, which invalidates pending and scheduled callbacks.

Authenticated API responses are classified by `ParsecAPIResponseClassifier`. Authenticated `401` or `403` responses require sign-in; login `401` or `403` responses remain credential rejection. Missing resources, rate limits, malformed success payloads, offline transport, and server failures have separate actionable categories. `ParsecRefreshTracker` rejects callbacks from older refresh generations and keeps the busy state active until every request in the current generation finishes.

Network diagnostics are content-free. `openparsec.network-recovery.state` and `openparsec.network-recovery.diagnostics` expose only generation, phase, consecutive failure count, reconnect-budget use, and numeric status. API failure digests expose only endpoint category, failure category, status code, and retryability. Tokens, credentials, peer IDs, host names, response bodies, and keyboard or controller data are forbidden.

Simulator UI scenarios prove automatic active reconnect, terminal replacement exhaustion, cancellation, expired authentication, and missing-host presentation. Real poor-network timing, NAT changes, server auth expiry, and SDK reconnect behavior remain physical iPad checks in S16 and S17.

## Media recovery and black-screen diagnostics

A transport-ready generation must prove video with a freshly rendered frame and audio with successful polling. The media watchdog requests one idempotent GL surface resume after 3 seconds without video, then one direct reconnect to the saved peer after 10 seconds without required video or audio. The reconnect budget follows that recovery episode into the replacement generation; another failure becomes a visible terminal `video` or `audio` diagnostic instead of another reconnect loop.

`CParsec.mediaRecoverySnapshot` and the in-session metrics overlay expose the generation, recovery phase, missing channel, reconnect budget, deadline, and latest renderer/audio status. Renderer status remains diagnostic evidence: a timeout does not itself terminate the session, while a negative raw status is retained in the terminal failure. These surfaces do not include peer IDs, session IDs, credentials, tokens, keyboard data, or media content.

DEBUG Simulator UI tests may shorten deadlines with `--media-soft-deadline=<seconds>` and `--media-hard-deadline=<seconds>` when `--ui-testing` is also present. Production and device builds always use the 3-second and 10-second deadlines. S06 consumes only an interactive media-ready generation or an explicit terminal diagnostic; S15 can inspect the same privacy-safe snapshot and raw status.

## Native and captured pointer modes

`Pointer Presentation` defaults to `Native Pointer`. UIKit leaves the iPadOS pointer unlocked, `UIHoverGestureRecognizer` maps its local position to absolute stream coordinates, and the immediate system pointer owns visual feedback while hover is active. Before pointer hover begins, touch-only sessions retain the host cursor as a fallback; the two cursors are never shown together.

`Captured Relative` explicitly requests pointer lock, sends coalesced indirect-pointer or `GCMouse` deltas, and renders the local dot while suppressing the delayed host cursor. `GCMouse` movement is ignored in native mode so it cannot duplicate the absolute hover path. Pointer ownership resets when the stream view disappears and is recomputed after reconnect or rotation.

DEBUG Simulator UI tests may select a mode with `--pointer-mode=native` or `--pointer-mode=captured` only when `--ui-testing` is present. Runtime state is available as `openparsec.pointer.state` and `openparsec.pointer.diagnostics`, and coordinate-free transitions use the `pointer` OSLog category. Simulator tests prove routing and ownership configuration; final movement feel and pointer-lock behavior require a physical iPad with a Magic Keyboard trackpad or external mouse.

## Pointer input, scrolling, and button safety

Touchpad-style finger motion, captured indirect-pointer motion, and captured `GCMouse` motion share the same sensitivity, acceleration, and sub-pixel accumulator. Two-finger touch, trackpad, and external-wheel scrolling preserve both axes and use the same scroll sensitivity and natural-direction transform. Trackpad momentum carries its live sub-pixel remainder; while zoomed, local `UIScrollView` pan owns scroll and remote wheel output is suppressed.

`CParsec` owns one exactly-once mouse-button latch across coordinate and relative sends. Duplicate presses/releases are ignored, and every pressed button is released before backgrounding, view disappearance, mouse disconnect, session disconnect, or reconnect. UI tests expose only `openparsec.mouse-buttons.state` and `openparsec.mouse-buttons.diagnostics`; diagnostics contain a pressed-button count and release reason, never coordinates, deltas, timing, peer identity, or input content.

## Keyboard lifecycle and privacy

Hardware key events are converted from UIKit HID usages to app-domain `RemoteKeyCode` values before they cross the `CParsec` service boundary. One generation-aware keyboard state forwards first key-down and repeat key-down events, accepts one matching key-up, ignores orphan key-ups, and releases all held keys before focus/view loss, background, disconnect, reconfigure, or reconnect. Left/right modifiers, navigation keys, and function keys use the same lifecycle.

On-screen modifier toggles and synthesized captured shortcuts join the same state through explicit down/up events. UIKit text insertion is emitted as bounded character taps, while named keys such as `BACKSPACE` remain one adapter tap. A lifecycle release also resets local chord suppression and visible accessory modifier toggles, so delayed synthetic releases become harmless ignored orphan-ups instead of affecting a replacement generation.

UI tests expose `openparsec.keyboard.state` and `openparsec.keyboard.diagnostics`. The digest contains generation, pressed count, repeat count, and release reason only; HID usages, key names, characters, typed text, modifier combinations, and shortcut contents are never logged or persisted. Public iPadOS APIs cannot capture every system-reserved shortcut; host-specific native chords and explicit remapping/UI alternatives are validated in S09/S10 and on physical hardware.

## macOS shortcut compatibility

OpenParsec classifies macOS actions by truthful delivery route:

| Action | Preferred route | Explicit alternative |
|---|---|---|
| Copy, paste, select all, new/close/minimize window | Raw hardware when delivered; priority `UIKeyCommand` capture when allowed | Toggle ⌘ in the keyboard bar, then tap the key; one-tap ⌘W is included |
| App switcher | Physical ⌘Tab is reserved by iPadOS and cannot be guaranteed | One-tap `⌘⇥` button |
| Spotlight or host input source | Physical ⌘Space is reserved by iPadOS and cannot be guaranteed | One-tap `⌘␣`, opt-in bare backtick, opt-in bare Ctrl Shift, or layout-sync hotkey |
| Hide application | Physical ⌘H is reserved by iPadOS | Use the ⌘ toolbar modifier plus H |
| Force Quit | Hardware availability varies | One-tap `⌘⌥⎋` button |
| Navigation and F1–F12 | Raw HID hardware events | Dedicated keyboard-bar keys |
| Globe key, iPad Home gesture, system swipe gestures | Not exposed reliably through public APIs | Choose a host hotkey or on-screen alternative; never claim native capture |

The `macOS Shortcut Buttons` setting controls the four one-tap alternatives. All macros execute synchronously through the S08 keyboard state: newly pressed keys go down in order and up in reverse; physically held modifiers remain held; a held trigger receives a repeat-down but is not released by the macro. Diagnostics expose only enabled state, catalog coverage count, completion count, and route category — never chord members.

Physical validation must cover representative actions against a macOS host. Priority capture is best effort even with `wantsPriorityOverSystemBehavior`; iPadOS remains authoritative for system-reserved combinations.

## Windows keyboard compatibility

Windows behavior is an explicit mode, not a bidirectional swap:

- **Direct HID** (default) forwards Control, Alt, and GUI as Ctrl, Alt, and Win unchanged.
- **Command as Control** maps GUI to Ctrl one-way; physical Control always stays Ctrl and never becomes Win.

Each key event carries an app-domain mapping intent. Only `ParsecSDKBridge` applies the configured mode; raw Windows macros pass `.raw` and bypass the editing remap so Win-key alternatives stay reachable in either mode. The keyboard bar offers Alt Tab, Start/Win, Win L, Ctrl Shift Esc (Task Manager), and Alt Shift layout switch. When a raw macro modifier overlaps a physically held configured modifier, the executor emits a transient balanced raw pair without changing ownership of the physical hold, so no host key is stranded.

Ctrl Alt Delete secure attention cannot be delivered through ordinary keyboard messages and is classified as unavailable; Ctrl Shift Esc is the supported Task Manager alternative. Diagnostics expose only the mode, whether buttons are enabled, catalog coverage, completion count, and route — never key codes or chord members. Physical iPad-to-Windows validation covers modifiers, Win-key alternatives, Alt Tab, the Task Manager alternative, navigation, function keys, and layout switching.

## Controllers and virtual controls

Gamepad input has one owner: `CParsec` holds a lock-protected `ParsecGamepadStateMachine`, mirroring the keyboard and mouse state owners. `GamepadController` stays a thin source that forwards `GCController` events to `CParsec`; it does not talk to the SDK adapter directly.

- **Balanced events.** Every button press/release and axis change routes through the state machine. Duplicate presses and orphan releases (a release for a button not currently held) are dropped, so the host never receives an unbalanced event.
- **Lifecycle release.** Held buttons are released (sent `false`) and non-neutral axes are neutralized (sent `0`) at every lifecycle boundary alongside the mouse and keyboard release: background, session disconnect, reconnect (generation change), view disappearance, and controller unplug. A controller cannot leave a stuck button or a deflected stick on the host across an app switch or reconnect.
- **Unplug.** When a controller disconnects, its held buttons and axes are released before the unplug message is sent.
- **Unsupported buttons.** The controller `guide`/home button has no Parsec host action. It is classified as unsupported and counted, never silently dropped into a no-op nor sent as a wrong button. All standard buttons (face, shoulders, stick clicks, d-pad, Start/Back) and axes (sticks, triggers) are supported.
- **On-screen and virtual controls.** The on-screen keyboard bar routes through `sendVirtualKeyboardInput`; toggleable modifier keys enter the same keyboard state machine and are released on every lifecycle boundary exactly like physical keys, while momentary keys are self-balancing bounded taps. Either way no on-screen key is stranded across reconnect.

Diagnostics expose only the gamepad pressed-button count, non-neutral-axis count, unsupported-button count, and last release reason — never analog stick or trigger positions as user content. Physical iPad controller validation (button balance, stick/trigger response, reconnect survival, unsupported-button behavior) is covered by the macOS and Windows host matrices.

## Settings contract

Every persisted setting is defined by one canonical registry: `ParsecSettingID`, `SettingsDefaults`, and `ParsecSettingsContract`. Runtime and SwiftUI `@AppStorage` wrappers reference canonical IDs/defaults rather than repeating string literals. The inventory is **30 persisted keys**: 24 user-visible controls plus 6 headless/session-saved keys (`bitrate`, `savedZoomEnabled`, `savedConstantFps`, `savedMuted`, `savedDisplayOutput`, `savedDisplayName`). Registry tests enforce unique IDs, complete descriptors, canonical defaults, persistence, classifications, and host applicability.

Each descriptor records: typed setting ID, canonical default, kind (user-visible control vs session-saved state), whether SettingsView renders a control, runtime-consumer summary, host applicability, application timing (live / reconnect / restored-on-connect), and dependency or migration notes.

Notable contract facts:

- **Host-specific controls.** `windowsKeyboardMode` remains Windows-only; `ctrlShiftEmulatesCmdSpace` and `backtickEmulatesCmdSpace` remain macOS-only. `hostShortcutToolbarMode` replaces the two toolbar booleans with Automatic/macOS/Windows/Both/Off. Automatic uses confirmed host OS information and safely shows both fallback groups while host OS is unknown.
- **Poor Network Preset.** **Apply Poor Network Preset** is an explicit action, not persisted profile state. It sets `preferredFramesPerSecond=0`, `decoder=.h265`, `noOverlay=true`, `decoderCompatibility=false`, and `bitrate=5`; each canonical setting remains independently authoritative afterward, and reconnect-only decoder changes are labeled as such.
- **Application timing.** Most interactivity/keyboard settings apply live; `resolution`, `decoder`, `decoderCompatibility`, and `bitrate` take effect on the next connect/reconnect; the `saved*` keys are restored when the host enumerates state at connect.
- **Migrations.** Launch-time one-way migrations preserve the legacy status-bar/cursor split, `localCursorOverlay` pointer ownership, Windows keyboard remap, and all four Mac/Windows shortcut-toolbar boolean combinations. Legacy keys are removed only after the canonical replacement is persisted.

Settings diagnostics expose only canonical setting IDs, apply mode/result, host category, migration state, coverage count, and user-visible count — never free-form values, typed content, peer/display IDs, or credentials.

## iPad Simulator platform

List installed runtimes and available iPad devices:

```bash
source scripts/xcode-env.sh
xcrun simctl list runtimes
xcrun simctl list devices available
```

Ask Xcode to download the current iOS Simulator platform when no iOS runtime is installed:

```bash
source scripts/xcode-env.sh
xcodebuild -downloadPlatform iOS
```

The vendored ParsecSDK remains a device-only production dependency. Simulator tests use the SDK-independent `ParsecService` contract and deterministic fake, while clean generic-device builds prove that the real adapter still compiles, links, and embeds the framework.

## Physical iPad

Installing a debug build on a physical iPad requires:

1. The iPad connected and trusted.
2. Developer Mode enabled on the iPad when requested by iPadOS.
3. An Apple ID team selected for the OpenParsec target in Xcode.
4. A valid development signing identity and provisioning profile.

A free Apple ID can be used for local development signing, subject to Apple's profile lifetime and entitlement limits. Never put Apple credentials in repository files or command history.

Inspect visible devices and signing identities:

```bash
source scripts/xcode-env.sh
xcrun devicectl list devices
security find-identity -v -p codesigning
```

Install and launch an already signed build:

```bash
xcrun devicectl device install app --device <device-id-or-name> <path-to-OpenParsec.app>
xcrun devicectl device process launch --device <device-id-or-name> com.aigch.OpenParsec
```

## Crash and device evidence

List and copy system crash logs from a connected device:

```bash
mkdir -p .build/device-crash-logs
xcrun devicectl device info files \
  --device <device-id-or-name> \
  --domain-type systemCrashLogs
xcrun devicectl device copy from \
  --device <device-id-or-name> \
  --domain-type systemCrashLogs \
  --source . \
  --destination .build/device-crash-logs
```

OpenParsec also persists its lightweight last-crash record in the app Documents container. Device and application logs must not include auth tokens, passwords, or typed keyboard content.

## Instruments

List available devices and templates:

```bash
source scripts/xcode-env.sh
xcrun xctrace list devices
xcrun xctrace list templates
```

Record a bounded Time Profiler trace from an installed app:

```bash
mkdir -p .build/traces
xcrun xctrace record \
  --template "Time Profiler" \
  --device <device-id-or-name> \
  --time-limit 60s \
  --output .build/traces/OpenParsec-Time-Profiler.trace \
  --launch -- com.aigch.OpenParsec
```

Later M002 slices add repeatable Allocations or Leaks, rendering, input-latency, and background-lifecycle trace procedures.
