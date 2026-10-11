import Foundation
import UIKit

enum ParsecAdapterKind: String, Codable, Equatable, Sendable {
    case uninitialized
    case real
    case fake
}

struct RemoteStatus: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: Int32

    init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    static let ok = RemoteStatus(rawValue: 0)
    static let connecting = RemoteStatus(rawValue: 20)
    static let notRunning = RemoteStatus(rawValue: -3)

    var isOK: Bool {
        self == .ok
    }

    var isConnecting: Bool {
        self == .connecting
    }

    var isFailure: Bool {
        rawValue < 0
    }

    /// Positive SDK warnings that mean the host ended or refused the session
    /// (shutdown, kicked, declined, canceled, no room, peer gone, no
    /// permission). Retrying or reconnecting would only be refused again.
    var endsSession: Bool {
        [4, 5, 8, 9, 11, 99, 112].contains(rawValue)
    }
}

struct ParsecRenderFrameResult: Equatable, Sendable {
    let status: RemoteStatus
    let producedFrame: Bool

    static func produced(status: RemoteStatus = .ok) -> ParsecRenderFrameResult {
        ParsecRenderFrameResult(status: status, producedFrame: true)
    }

    static func noFrame(status: RemoteStatus) -> ParsecRenderFrameResult {
        ParsecRenderFrameResult(status: status, producedFrame: false)
    }
}

struct ParsecMediaEvidence: Equatable, Sendable {
    var readiness: ParsecMediaReadiness
    var videoStatus: RemoteStatus?
    var audioStatus: RemoteStatus?

    static let initial = ParsecMediaEvidence(
        readiness: .notReady,
        videoStatus: nil,
        audioStatus: nil
    )
}

struct RemoteClientMetrics: Equatable, Sendable {
    var decodeLatency: Double = 0
    var encodeLatency: Double = 0
    var networkLatency: Double = 0
    var bitrate: Double = 0
    var queuedFrames: UInt32 = 0
    var fastRetransmits: UInt32 = 0
    var slowRetransmits: UInt32 = 0
}

struct RemoteDecoderStatus: Equatable, Sendable {
    var name: String = ""
    var width: UInt32 = 0
    var height: UInt32 = 0
    var usesH265 = false
    var usesColor444 = false
}

struct RemoteClientStatus: Equatable, Sendable {
    var status: RemoteStatus = .ok
    var metrics = RemoteClientMetrics()
    var decoder = RemoteDecoderStatus()
}

struct RemoteMouseButton: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let left = RemoteMouseButton(rawValue: 1)
    static let middle = RemoteMouseButton(rawValue: 2)
    static let right = RemoteMouseButton(rawValue: 3)
    static let extra1 = RemoteMouseButton(rawValue: 4)
    static let extra2 = RemoteMouseButton(rawValue: 5)
}

struct RemoteGamepadButton: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let a = RemoteGamepadButton(rawValue: 0)
    static let b = RemoteGamepadButton(rawValue: 1)
    static let x = RemoteGamepadButton(rawValue: 2)
    static let y = RemoteGamepadButton(rawValue: 3)
    static let back = RemoteGamepadButton(rawValue: 4)
    static let guide = RemoteGamepadButton(rawValue: 5)
    static let start = RemoteGamepadButton(rawValue: 6)
    static let leftStick = RemoteGamepadButton(rawValue: 7)
    static let rightStick = RemoteGamepadButton(rawValue: 8)
    static let leftShoulder = RemoteGamepadButton(rawValue: 9)
    static let rightShoulder = RemoteGamepadButton(rawValue: 10)
    static let dpadUp = RemoteGamepadButton(rawValue: 11)
    static let dpadDown = RemoteGamepadButton(rawValue: 12)
    static let dpadLeft = RemoteGamepadButton(rawValue: 13)
    static let dpadRight = RemoteGamepadButton(rawValue: 14)
}

struct RemoteGamepadAxis: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let leftX = RemoteGamepadAxis(rawValue: 0)
    static let leftY = RemoteGamepadAxis(rawValue: 1)
    static let rightX = RemoteGamepadAxis(rawValue: 2)
    static let rightY = RemoteGamepadAxis(rawValue: 3)
    static let leftTrigger = RemoteGamepadAxis(rawValue: 4)
    static let rightTrigger = RemoteGamepadAxis(rawValue: 5)
}

struct RemoteKeyCode: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

struct ParsecGenerationRequestGate {
    private var lastClaimedGeneration: UInt64?

    mutating func claim(generation: UInt64) -> Bool {
        guard lastClaimedGeneration != generation else { return false }
        lastClaimedGeneration = generation
        return true
    }
}

enum RendererType: Int {
    case opengl
    case metal
}

enum DecoderPref: Int {
    case h264
    case h265
}

enum CursorMode: Int {
    case touchpad
    case direct
}

enum PointerPresentationMode: Int, CaseIterable {
    case native
    case captured
}

enum ParsecPointerInputRoute: String, Equatable {
    case absolute
    case relative
}

enum ParsecPointerCursorOwner: String, Equatable {
    case host
    case system
    case local
}

struct ParsecPointerButtonMaskSnapshot: Equatable {
    let primaryPressed: Bool
    let secondaryPressed: Bool

    init(buttonMask: UIEvent.ButtonMask) {
        primaryPressed = buttonMask.contains(.primary)
        secondaryPressed = buttonMask.contains(.secondary)
    }
}

struct ParsecPointerMotionOwnership {
    static func usesHover(
        route: ParsecPointerInputRoute,
        pressedButtonCount: Int
    ) -> Bool {
        route == .absolute && pressedButtonCount == 0
    }

    static func usesNativeDragPan(
        route: ParsecPointerInputRoute,
        pressedButtonCount: Int
    ) -> Bool {
        route == .absolute && pressedButtonCount > 0
    }
}

struct ParsecInputDelta: Equatable {
    let x: Double
    let y: Double
}

struct ParsecIntegerInputDelta: Equatable {
    let x: Int32
    let y: Int32
}

struct ParsecTransportObservationPolicy {
    static func isAllowed(applicationState: UIApplication.State) -> Bool {
        applicationState == .active
    }
}

struct ParsecRecoveryPresentationPolicy {
    static func shouldDismissSession(
        pictureInPictureActive: Bool,
        automaticReconnectPending: Bool,
        preservesBackgroundPresentation: Bool
    ) -> Bool {
        !pictureInPictureActive
            && !(automaticReconnectPending && preservesBackgroundPresentation)
    }
}

struct ParsecPiPCapturePolicy {
    static func shouldCapture(
        isActive: Bool,
        isStarting: Bool,
        hasPreparedSample: Bool
    ) -> Bool {
        isActive || isStarting || !hasPreparedSample
    }
}

enum ParsecPiPDidStartAction: Equatable {
    case activateProtection
    case stopWithoutProtection
    case ignore
}

struct ParsecPiPTransitionPolicy {
    static func shouldLatchCancellation(
        isStarting: Bool,
        startSubmittedToAVKit: Bool
    ) -> Bool {
        isStarting && startSubmittedToAVKit
    }

    static func didStartAction(
        isExpectedController: Bool,
        isStarting: Bool,
        cancelRequestedWhileStarting: Bool
    ) -> ParsecPiPDidStartAction {
        guard isExpectedController else { return .ignore }
        if cancelRequestedWhileStarting { return .stopWithoutProtection }
        return isStarting ? .activateProtection : .ignore
    }
}

struct ParsecPiPStartPolicy {
    static func isReady(
        isSetup: Bool,
        isActive: Bool,
        isStarting: Bool,
        hasController: Bool,
        hasAttachedSource: Bool,
        hasSampleBuffer: Bool,
        layerFailed: Bool
    ) -> Bool {
        isSetup
            && !isActive
            && !isStarting
            && hasController
            && hasAttachedSource
            && hasSampleBuffer
            && !layerFailed
    }
}

struct ParsecTouchInteractionPolicy {
    static let dragMinimumPressDuration: TimeInterval = 0.18
    static let dragAllowableMovement: CGFloat = 36

    static func shouldInterruptScrollMomentum(
        for state: UIGestureRecognizer.State
    ) -> Bool {
        state == .began
    }

    static func shouldInterruptTrackpadMomentum(
        for state: UIGestureRecognizer.State
    ) -> Bool {
        state == .began || state == .changed
    }
}

struct ParsecScrollMomentumPolicy {
    static let minimumFlickTravel = 12.0
    static let minimumFlickSpeed = 60.0
    static let maximumGlideDuration = 1.2
    // ponytail: device logs show lift-off velocities of 8–12k pt/s, which
    // glided ~10x the gesture's own travel. Cap the seed; tune from the
    // scroll-gesture diagnostics if flicks feel short.
    static let maximumStartSpeed = 3000.0

    static func glideSeed(_ velocity: ParsecInputDelta) -> ParsecInputDelta {
        let speed = hypot(velocity.x, velocity.y)
        guard speed > maximumStartSpeed else { return velocity }
        let scale = maximumStartSpeed / speed
        return ParsecInputDelta(x: velocity.x * scale, y: velocity.y * scale)
    }

    static func shouldStart(travel: Double, peakSpeed: Double) -> Bool {
        travel >= minimumFlickTravel && peakSpeed >= minimumFlickSpeed
    }

    static func clampedDuration(_ duration: TimeInterval) -> TimeInterval {
        min(max(duration, 0), maximumGlideDuration)
    }

    static func peakVelocity(
        current: ParsecInputDelta,
        candidate: ParsecInputDelta
    ) -> ParsecInputDelta {
        // Keep the fastest sample so iPadOS's pre-decelerated tail still
        // seeds a flick, but a gesture slowed below flick speed before lift
        // is a deliberate stop: adopt the latest (lower) velocity so it
        // doesn't glide.
        let candidateSpeed = hypot(candidate.x, candidate.y)
        guard candidateSpeed.isFinite else { return current }
        return candidateSpeed > hypot(current.x, current.y)
            || candidateSpeed < minimumFlickSpeed
            ? candidate
            : current
    }

    static func shouldContinue(
        elapsed: TimeInterval,
        maximumDuration: TimeInterval
    ) -> Bool {
        maximumDuration > 0 && elapsed < maximumDuration
    }
}

enum ParsecVirtualKeyTap {
    static let leftShift: UInt32 = 225

    /// Ordered press/release events for one soft-keyboard tap. Shift is
    /// injected (and released after the key) only when the character needs
    /// it and the user isn't already holding virtual Shift.
    static func sequence(
        code: UInt32,
        needsShift: Bool,
        shiftHeld: Bool
    ) -> [(code: UInt32, pressed: Bool)] {
        guard needsShift && !shiftHeld else {
            return [(code, true), (code, false)]
        }
        return [(leftShift, true), (code, true), (code, false), (leftShift, false)]
    }
}

struct ParsecPointerTransform {
    static func movement(
        x: Double,
        y: Double,
        sensitivity: Double,
        acceleration: Double
    ) -> ParsecInputDelta {
        let safeSensitivity = max(0, sensitivity)
        let safeAcceleration = max(0, acceleration)
        let speed = hypot(x, y) / 5.0
        let scale = safeSensitivity + safeAcceleration * speed
        return ParsecInputDelta(x: x * scale, y: y * scale)
    }

    static func scroll(
        x: Double,
        y: Double,
        sensitivity: Double,
        natural: Bool
    ) -> ParsecInputDelta {
        let direction = natural ? 1.0 : -1.0
        let scale = max(0, sensitivity) * direction
        return ParsecInputDelta(x: x * scale, y: y * scale)
    }
}

struct ParsecDeltaAccumulator: Equatable {
    private(set) var x = 0.0
    private(set) var y = 0.0

    mutating func consume(_ delta: ParsecInputDelta) -> ParsecIntegerInputDelta? {
        // One NaN/inf delta would poison the remainder and trap in Int32(_:).
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        x = min(max(x + delta.x, -1e9), 1e9)   // keep Int32(_:) below from trapping
        y = min(max(y + delta.y, -1e9), 1e9)
        let wholeX = Int32(x.rounded(.toNearestOrAwayFromZero))
        let wholeY = Int32(y.rounded(.toNearestOrAwayFromZero))
        guard wholeX != 0 || wholeY != 0 else { return nil }
        x -= Double(wholeX)
        y -= Double(wholeY)
        return ParsecIntegerInputDelta(x: wholeX, y: wholeY)
    }

    mutating func reset() {
        x = 0
        y = 0
    }
}

enum ParsecMouseReleaseReason: String, Equatable {
    case none
    case normal
    case gestureCancelled = "gesture-cancelled"
    case viewDisappeared = "view-disappeared"
    case mouseDisconnected = "mouse-disconnected"
    case sessionDisconnected = "session-disconnected"
    case background
    case reconnect
}

struct ParsecMouseInputSnapshot: Equatable {
    let pressedCount: Int
    let lastReleaseReason: ParsecMouseReleaseReason

    var digest: String {
        "pressed=\(pressedCount) release=\(lastReleaseReason.rawValue)"
    }
}

struct ParsecMouseButtonLatch: Equatable {
    private(set) var pressed: Set<RemoteMouseButton> = []

    var pressedCount: Int {
        pressed.count
    }

    mutating func update(_ button: RemoteMouseButton, pressed nextPressed: Bool) -> Bool {
        if nextPressed {
            return pressed.insert(button).inserted
        }
        return pressed.remove(button) != nil
    }

    mutating func releaseAll() -> [RemoteMouseButton] {
        let buttons = pressed.sorted { $0.rawValue < $1.rawValue }
        pressed.removeAll()
        return buttons
    }

    var digest: String {
        "pressed=\(pressedCount)"
    }
}

enum ParsecKeyboardReleaseReason: String, Equatable {
    case none
    case normal
    case cancelled
    case focusLost = "focus-lost"
    case viewDisappeared = "view-disappeared"
    case background
    case sessionDisconnected = "session-disconnected"
    case reconnect
    case settingsChanged = "settings-changed"
}

enum ParsecKeyboardTransition: Equatable {
    case pressed
    case repeated
    case released
    case ignored
}

struct ParsecKeyboardSnapshot: Equatable {
    let generation: UInt64
    let pressedCount: Int
    let repeatCount: UInt64
    let lastReleaseReason: ParsecKeyboardReleaseReason

    var digest: String {
        "generation=\(generation) pressed=\(pressedCount) "
            + "repeats=\(repeatCount) release=\(lastReleaseReason.rawValue)"
    }
}

struct ParsecKeyboardStateMachine: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var pressed: Set<RemoteKeyCode> = []
    private(set) var repeatCount: UInt64 = 0
    private(set) var lastReleaseReason: ParsecKeyboardReleaseReason = .none

    var snapshot: ParsecKeyboardSnapshot {
        ParsecKeyboardSnapshot(
            generation: generation,
            pressedCount: pressed.count,
            repeatCount: repeatCount,
            lastReleaseReason: lastReleaseReason
        )
    }

    mutating func press(_ key: RemoteKeyCode) -> ParsecKeyboardTransition {
        if pressed.insert(key).inserted {
            return .pressed
        }
        repeatCount &+= 1
        return .repeated
    }

    mutating func release(
        _ key: RemoteKeyCode,
        reason: ParsecKeyboardReleaseReason = .normal
    ) -> ParsecKeyboardTransition {
        guard pressed.remove(key) != nil else { return .ignored }
        lastReleaseReason = reason
        return .released
    }

    mutating func releaseAll(reason: ParsecKeyboardReleaseReason) -> [RemoteKeyCode] {
        let keys = pressed.sorted { $0.rawValue < $1.rawValue }
        pressed.removeAll()
        lastReleaseReason = reason
        return keys
    }

    mutating func beginGeneration(
        _ nextGeneration: UInt64,
        releaseReason: ParsecKeyboardReleaseReason = .reconnect
    ) -> [RemoteKeyCode] {
        let released = releaseAll(reason: releaseReason)
        generation = nextGeneration
        repeatCount = 0
        return released
    }
}

enum ParsecGamepadReleaseReason: String, Equatable {
    case none
    case normal
    case controllerDisconnected = "controller-disconnected"
    case viewDisappeared = "view-disappeared"
    case background
    case sessionDisconnected = "session-disconnected"
    case reconnect
}

enum ParsecGamepadTransition: Equatable {
    case pressed
    case released
    case ignored
}

/// Truthful support classification for a physical controller button. `guide`
/// (the PlayStation/Xbox home button) is wired by GameController but Parsec's
/// host protocol exposes no home-button action, so it is surfaced as
/// unsupported (counted) rather than silently dropped or sent as a wrong
/// button.
enum ParsecGamepadButtonSupport {
    static let unsupported: Set<RemoteGamepadButton> = [.guide]

    static func isSupported(_ button: RemoteGamepadButton) -> Bool {
        !unsupported.contains(button)
    }
}

struct ParsecGamepadSnapshot: Equatable {
    let generation: UInt64
    let pressedCount: Int
    let nonNeutralAxisCount: Int
    let unsupportedCount: UInt64
    let lastReleaseReason: ParsecGamepadReleaseReason

    var digest: String {
        "generation=\(generation) pressed=\(pressedCount) "
            + "axes=\(nonNeutralAxisCount) unsupported=\(unsupportedCount) "
            + "release=\(lastReleaseReason.rawValue)"
    }
}

/// Single owner of gamepad input state, mirroring `ParsecKeyboardStateMachine`.
/// Tracks pressed buttons and non-neutral axes per controller id so that every
/// lifecycle boundary can release held buttons (to false) and neutralize axes
/// (to 0) exactly once, producing balanced host events across reconnect.
struct ParsecGamepadStateMachine: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var pressed: [UInt32: Set<RemoteGamepadButton>] = [:]
    private(set) var nonNeutralAxes: [UInt32: Set<RemoteGamepadAxis>] = [:]
    private(set) var unsupportedCount: UInt64 = 0
    private(set) var lastReleaseReason: ParsecGamepadReleaseReason = .none

    var pressedCount: Int {
        pressed.values.reduce(0) { $0 + $1.count }
    }

    var nonNeutralAxisCount: Int {
        nonNeutralAxes.values.reduce(0) { $0 + $1.count }
    }

    var snapshot: ParsecGamepadSnapshot {
        ParsecGamepadSnapshot(
            generation: generation,
            pressedCount: pressedCount,
            nonNeutralAxisCount: nonNeutralAxisCount,
            unsupportedCount: unsupportedCount,
            lastReleaseReason: lastReleaseReason
        )
    }

    /// Records a button press/release. Unsupported buttons are counted and
    /// return `.ignored` so no host message is sent. Orphan releases (a release
    /// for a button not currently held) also return `.ignored`.
    mutating func button(
        _ button: RemoteGamepadButton,
        pressed nextPressed: Bool,
        controllerId: UInt32
    ) -> ParsecGamepadTransition {
        guard ParsecGamepadButtonSupport.isSupported(button) else {
            unsupportedCount &+= 1
            return .ignored
        }
        if nextPressed {
            if pressed[controllerId, default: []].insert(button).inserted {
                return .pressed
            }
            return .ignored
        }
        guard pressed[controllerId]?.remove(button) != nil else {
            return .ignored
        }
        if pressed[controllerId]?.isEmpty == true {
            pressed[controllerId] = nil
        }
        lastReleaseReason = .normal
        return .released
    }

    /// Records an axis value, tracking whether it is currently non-neutral so a
    /// later releaseAll can zero exactly the axes that need it.
    mutating func axis(
        _ axis: RemoteGamepadAxis,
        value: Int16,
        controllerId: UInt32
    ) {
        if value == 0 {
            if nonNeutralAxes[controllerId]?.remove(axis) != nil,
               nonNeutralAxes[controllerId]?.isEmpty == true {
                nonNeutralAxes[controllerId] = nil
            }
        } else {
            nonNeutralAxes[controllerId, default: []].insert(axis)
        }
    }

    /// Ordered (controllerId, button) pairs that must be released, plus the
    /// (controllerId, axis) pairs that must be zeroed, then clears all state.
    mutating func releaseAll(
        reason: ParsecGamepadReleaseReason
    ) -> (buttons: [(UInt32, RemoteGamepadButton)], axes: [(UInt32, RemoteGamepadAxis)]) {
        var buttons: [(UInt32, RemoteGamepadButton)] = []
        for controllerId in pressed.keys.sorted() {
            for button in pressed[controllerId]!.sorted(by: { $0.rawValue < $1.rawValue }) {
                buttons.append((controllerId, button))
            }
        }
        var axes: [(UInt32, RemoteGamepadAxis)] = []
        for controllerId in nonNeutralAxes.keys.sorted() {
            for axis in nonNeutralAxes[controllerId]!.sorted(by: { $0.rawValue < $1.rawValue }) {
                axes.append((controllerId, axis))
            }
        }
        pressed.removeAll()
        nonNeutralAxes.removeAll()
        lastReleaseReason = reason
        return (buttons, axes)
    }

    /// Releases everything for a controller that is unplugging.
    mutating func releaseController(
        _ controllerId: UInt32,
        reason: ParsecGamepadReleaseReason = .controllerDisconnected
    ) -> (buttons: [RemoteGamepadButton], axes: [RemoteGamepadAxis]) {
        let buttons = (pressed[controllerId] ?? []).sorted { $0.rawValue < $1.rawValue }
        let axes = (nonNeutralAxes[controllerId] ?? []).sorted { $0.rawValue < $1.rawValue }
        pressed[controllerId] = nil
        nonNeutralAxes[controllerId] = nil
        if !buttons.isEmpty || !axes.isEmpty {
            lastReleaseReason = reason
        }
        return (buttons, axes)
    }

    mutating func beginGeneration(
        _ nextGeneration: UInt64,
        releaseReason: ParsecGamepadReleaseReason = .reconnect
    ) -> (buttons: [(UInt32, RemoteGamepadButton)], axes: [(UInt32, RemoteGamepadAxis)]) {
        let released = releaseAll(reason: releaseReason)
        generation = nextGeneration
        return released
    }
}

/// Content-free accounting of concurrency-sensitive resources so tests can
/// prove balance and leak-freeness that the bridge previously only documented
/// in comments. Buffers track ParsecGetBuffer/ParsecFree pairs; generation is
/// the monotonic poll generation; timers/observers track add/remove balance;
/// cycles counts connect/disconnect rounds. Counts only, never payloads.
struct ParsecResourceLedger: Equatable, Sendable {
    private(set) var acquiredBuffers: Int = 0
    private(set) var freedBuffers: Int = 0
    private(set) var pollGeneration: UInt64 = 0
    private(set) var addedTimers: Int = 0
    private(set) var removedTimers: Int = 0
    private(set) var addedObservers: Int = 0
    private(set) var removedObservers: Int = 0
    private(set) var connectCycles: Int = 0

    var outstandingBuffers: Int { acquiredBuffers - freedBuffers }
    var activeTimers: Int { addedTimers - removedTimers }
    var activeObservers: Int { addedObservers - removedObservers }

    /// True when nothing is outstanding: no unfreed buffers, no net timers,
    /// no net observers.
    var isBalanced: Bool {
        outstandingBuffers == 0 && activeTimers == 0 && activeObservers == 0
    }

    var digest: String {
        "gen=\(pollGeneration) buffers=\(outstandingBuffers) "
            + "timers=\(activeTimers) observers=\(activeObservers) "
            + "cycles=\(connectCycles)"
    }

    mutating func acquireBuffer() { acquiredBuffers += 1 }
    mutating func freeBuffer() { freedBuffers += 1 }
    mutating func addTimer() { addedTimers += 1 }
    mutating func removeTimer() { removedTimers += 1 }
    mutating func addObserver() { addedObservers += 1 }
    mutating func removeObserver() { removedObservers += 1 }
    mutating func recordConnectCycle() { connectCycles += 1 }

    /// Advances the poll generation only if the new value is strictly greater,
    /// enforcing monotonicity. Returns true when accepted.
    @discardableResult
    mutating func advanceGeneration(to next: UInt64) -> Bool {
        guard next > pollGeneration else { return false }
        pollGeneration = next
        return true
    }
}

enum ParsecTransportRecoveryPhase: String, Equatable, Sendable {
    case monitoring
    case reconnectRequested = "reconnect-requested"
    case terminal
    case cancelled
}

enum ParsecTransportRecoveryEffect: Equatable, Sendable {
    case reconnect(generation: UInt64)
    case terminal(generation: UInt64, status: RemoteStatus)
}

struct ParsecTransportRecoverySnapshot: Equatable, Sendable {
    let generation: UInt64
    let phase: ParsecTransportRecoveryPhase
    let consecutiveFailures: Int
    let reconnectBudgetUsed: Bool
    let lastStatus: RemoteStatus

    var digest: String {
        "generation=\(generation) phase=\(phase.rawValue) "
            + "failures=\(consecutiveFailures) "
            + "reconnectUsed=\(reconnectBudgetUsed) "
            + "status=\(lastStatus.rawValue)"
    }
}

/// DECODE_ERR_* (-10…-23). A decode error is a dead video pipeline, not a
/// latch to wait out (ParsecSDK arm64): vt_decode_frame (0x82b7c) maps any
/// VTDecompressionSessionDecodeFrame failure to -14 (0x82d88); decode_thread
/// stores it as the stream status (0x7dfb8) and exits on its next loop check
/// (0x7dd70 → 0x7e704). Only ParsecClientConnect starts a new decode_thread,
/// so the reconnect is the only remedy once this status appears.
enum ParsecDecodeErrorPolicy {
    static func isDecodeError(_ status: RemoteStatus) -> Bool {
        (-23 ... -10).contains(status.rawValue)
    }
}

/// Keeps the VideoToolbox session from ever decoding after iPadOS invalidated
/// it (see ParsecDecodeErrorPolicy for why that is fatal). Evidence:
/// - ParsecClientPause (0x7a7c4) only sends msg 0x16 {video, audio}; it does
///   not touch the client decoder. The SDK host marks a resumed guest for an
///   encoder reinit/keyframe (0x7f524).
/// - decode_thread compares the pending ParsecClientSetConfig fields with the
///   applied ones each loop (0x7ddd0). On a change it destroys the decoder
///   (0x7df30) and sends msg 0xd with reset=1 (0x7ded4); the SDK host answers
///   that with a keyframe (0x7f230). Until a frame with SPS/VPS rebuilds the
///   decoder (0x7e0b8), other frames are dropped without error (0x7e29c).
/// - vt_init_hw (0x82558) ignores decoderCompatibility, so flipping it resets
///   the decoder and changes nothing else.
enum ParsecVideoSuspendPolicy {
    enum Recovery: Equatable {
        case waiting, recovered, failed, nudge, stalled
    }

    static let nudgeAfter: TimeInterval = 1.0
    static let stallAfter: TimeInterval = 3.0

    /// decoderCompatibility is inert for the VideoToolbox decoder (vt_init_hw
    /// ignores it), but decode_thread drops its decoder whenever the config
    /// changes. Toggling `flipped` on every resume therefore forces a fresh
    /// decoder (rebuilt from the next keyframe, in the foreground) without
    /// a second reset to restore the user's value.
    static func decoderCompatibility(user: Bool, flipped: Bool) -> Bool {
        user != flipped
    }

    /// `decoded`: metrics.decodeLatency changed since resume. decode_thread
    /// writes it only after a successful decode (0x7e360…0x7e388), while
    /// GLRenderFrame returns OK for re-draws too (0x7ce98).
    static func recovery(
        elapsed: TimeInterval,
        decoded: Bool,
        status: RemoteStatus,
        nudged: Bool,
        rttMs: Float = 0
    ) -> Recovery {
        if ParsecDecodeErrorPolicy.isDecodeError(status) { return .failed }
        if decoded { return .recovered }
        // A keyframe over a slow VPN routinely needs > 1 s: scale with RTT so
        // a slow link waits instead of nudging/reconnecting (capped).
        let rtt = rttMs.isFinite ? TimeInterval(max(0, rttMs)) / 1000 : 0
        if elapsed >= min(max(stallAfter, 10 * rtt), 8) { return .stalled }
        if elapsed >= min(max(nudgeAfter, 4 * rtt), 3) && !nudged { return .nudge }
        return .waiting
    }

    /// Highest encoder bitrate (Mbps) the client will ever request from the host.
    ///
    /// The SDK's BUD frame reassembler `bud_write_packet` (ParsecSDK 0x722e4)
    /// rebuilds each encoded frame by concatenating packet fragments into the
    /// caller's decode buffer. It bounds-checks only the *declared* total frame
    /// size against the buffer capacity (0x723c4; rejects with -0x2eeb), then
    /// runs a copy loop (0x724cc–0x72518) that adds each per-packet length
    /// (ldrsw [slot+0xbb8]) and decrements a byte counter w24, stopping only when
    /// w24 hits exactly 0. No per-fragment length is re-validated against the
    /// remaining count, so a lost / duplicated / ring-wrapped fragment whose
    /// lengths don't sum to the declared total underflows w24 and the loop walks
    /// past the buffer — SIGSEGV in the memcpy at 0x724f0 (crash return
    /// ParsecSDK+468212 = 0x724f4, reached from decode_thread via
    /// ParsecVersion+4284). A large frame is split into more fragments
    /// (ceil((total+4)/[ctx+0x440])), so the loss/reorder that accompanies a
    /// fresh session's congested ramp-up is far likelier to corrupt the
    /// bookkeeping on a big H.265 keyframe for a 3024x1964 desktop.
    ///
    /// Field evidence (iPad Pro M4, LAN, macOS host, 3024x1964 H.265): SIGSEGV at
    /// this exact site at 40 Mbps (Jul) and 50 Mbps, no crash at 20 Mbps — so 20
    /// is the only empirically safe ceiling. `0` ("Host Default") adopts the
    /// host's own value from its first echo, so it is capped to 20 as well.
    /// ponytail: raised to 30 at the user's request (2026-10-12): untested
    /// between 20 and 40; drop back to 20 if the 0x724f4 crash reappears.
    static let maxSafeHostBitrate = 30

    static func safeHostBitrate(_ requested: Int) -> Int {
        requested > 0 ? min(requested, maxSafeHostBitrate) : requested
    }
}

/// Pure generation-aware policy for active-session transport loss. It owns no
/// timers or SDK effects: callers execute the single reconnect or terminal
/// effect through the existing lifecycle coordinator.
struct ParsecTransportRecoveryMonitor {
    let failureThreshold: Int
    private(set) var snapshot: ParsecTransportRecoverySnapshot

    init(failureThreshold: Int = 5) {
        precondition(failureThreshold > 0)
        self.failureThreshold = failureThreshold
        snapshot = ParsecTransportRecoverySnapshot(
            generation: 0,
            phase: .monitoring,
            consecutiveFailures: 0,
            reconnectBudgetUsed: false,
            lastStatus: .notRunning
        )
    }

    mutating func observe(
        status: RemoteStatus,
        generation: UInt64,
        isReplacementGeneration: Bool,
        isSessionInteractive: Bool = false,
        isObservationAllowed: Bool = true
    ) -> ParsecTransportRecoveryEffect? {
        if generation > snapshot.generation {
            snapshot = ParsecTransportRecoverySnapshot(
                generation: generation,
                phase: .monitoring,
                consecutiveFailures: 0,
                reconnectBudgetUsed: isReplacementGeneration,
                lastStatus: status
            )
        } else if generation < snapshot.generation {
            return nil
        }

        guard isObservationAllowed else { return nil }
        guard snapshot.phase == .monitoring else { return nil }

        // PARSEC_CONNECTING (raw 20) is progress, not transport failure. A
        // replacement generation may legitimately report it for more than the
        // five active-session failure polls, so it must never consume the one
        // reconnect budget or surface "Error 20".
        if status.endsSession {
            snapshot = ParsecTransportRecoverySnapshot(
                generation: generation,
                phase: .terminal,
                consecutiveFailures: snapshot.consecutiveFailures,
                reconnectBudgetUsed: snapshot.reconnectBudgetUsed,
                lastStatus: status
            )
            return .terminal(generation: generation, status: status)
        }

        // CONNECTING and other positive warnings (e.g. NETWORK_WRN_TIMEOUT)
        // are progress, not failure.
        if status != .ok && !status.isFailure {
            snapshot = ParsecTransportRecoverySnapshot(
                generation: generation,
                phase: .monitoring,
                consecutiveFailures: 0,
                reconnectBudgetUsed: snapshot.reconnectBudgetUsed,
                lastStatus: status
            )
            return nil
        }

        if status == .ok {
            snapshot = ParsecTransportRecoverySnapshot(
                generation: generation,
                phase: .monitoring,
                consecutiveFailures: 0,
                // A replacement remains inside the same recovery episode
                // until media is interactive, not merely transport-OK.
                reconnectBudgetUsed: snapshot.reconnectBudgetUsed
                    && !isSessionInteractive,
                lastStatus: status
            )
            return nil
        }

        let failures = snapshot.consecutiveFailures + 1
        // A latched decode error never clears by itself: waiting out the
        // streak only prolongs the frozen picture.
        guard failures >= failureThreshold
            || ParsecDecodeErrorPolicy.isDecodeError(status) else {
            snapshot = ParsecTransportRecoverySnapshot(
                generation: generation,
                phase: .monitoring,
                consecutiveFailures: failures,
                reconnectBudgetUsed: snapshot.reconnectBudgetUsed,
                lastStatus: status
            )
            return nil
        }

        if snapshot.reconnectBudgetUsed {
            snapshot = ParsecTransportRecoverySnapshot(
                generation: generation,
                phase: .terminal,
                consecutiveFailures: failures,
                reconnectBudgetUsed: true,
                lastStatus: status
            )
            return .terminal(generation: generation, status: status)
        }

        snapshot = ParsecTransportRecoverySnapshot(
            generation: generation,
            phase: .reconnectRequested,
            consecutiveFailures: failures,
            reconnectBudgetUsed: true,
            lastStatus: status
        )
        return .reconnect(generation: generation)
    }

    mutating func cancel(generation: UInt64) {
        guard generation >= snapshot.generation else { return }
        snapshot = ParsecTransportRecoverySnapshot(
            generation: generation,
            phase: .cancelled,
            consecutiveFailures: snapshot.consecutiveFailures,
            reconnectBudgetUsed: snapshot.reconnectBudgetUsed,
            lastStatus: snapshot.lastStatus
        )
    }
}

/// Content-free facade snapshot used to prove that repeated connection cycles
/// advance monotonically and leave no held input behind.
struct ParsecConcurrencySnapshot: Equatable, Sendable {
    let generation: UInt64
    let outstandingInput: Int
    let outstandingBuffers: Int
    let activeTimers: Int
    let activeObservers: Int
    let connectCycles: Int

    var isAtRest: Bool {
        outstandingInput == 0
            && outstandingBuffers == 0
            && activeTimers == 0
            && activeObservers == 0
    }

    var digest: String {
        "generation=\(generation) input=\(outstandingInput) "
            + "buffers=\(outstandingBuffers) timers=\(activeTimers) "
            + "observers=\(activeObservers) cycles=\(connectCycles)"
    }
}

enum HostShortcutToolbarMode: Int, CaseIterable, Equatable {
    case automatic
    case macOS
    case windows
    case both
    case off

    var diagnosticName: String {
        switch self {
        case .automatic: return "automatic"
        case .macOS: return "macos"
        case .windows: return "windows"
        case .both: return "both"
        case .off: return "off"
        }
    }
}

struct ParsecHostShortcutVisibility: Equatable {
    let showMac: Bool
    let showWindows: Bool
}

enum ParsecHostShortcutToolbarPolicy {
    static func migrate(
        showMac: Bool?,
        showWindows: Bool?
    ) -> HostShortcutToolbarMode {
        guard showMac != nil || showWindows != nil else { return .automatic }
        switch (showMac ?? true, showWindows ?? true) {
        case (true, true): return .both
        case (true, false): return .macOS
        case (false, true): return .windows
        case (false, false): return .off
        }
    }

    static func visibility(
        mode: HostShortcutToolbarMode,
        host: HostOS
    ) -> ParsecHostShortcutVisibility {
        switch mode {
        case .automatic:
            switch host {
            case .macos:
                return ParsecHostShortcutVisibility(
                    showMac: true,
                    showWindows: false
                )
            case .windows:
                return ParsecHostShortcutVisibility(
                    showMac: false,
                    showWindows: true
                )
            case .unknown, .linux:
                return ParsecHostShortcutVisibility(
                    showMac: true,
                    showWindows: true
                )
            }
        case .macOS:
            return ParsecHostShortcutVisibility(
                showMac: true,
                showWindows: false
            )
        case .windows:
            return ParsecHostShortcutVisibility(
                showMac: false,
                showWindows: true
            )
        case .both:
            return ParsecHostShortcutVisibility(
                showMac: true,
                showWindows: true
            )
        case .off:
            return ParsecHostShortcutVisibility(
                showMac: false,
                showWindows: false
            )
        }
    }
}

enum WindowsKeyboardMode: Int, CaseIterable, Equatable {
    case direct
    case commandAsControl
}

enum ParsecKeyboardMappingIntent: Equatable {
    case configured
    case raw
}

enum ParsecWindowsKeyboardMapping {
    static func map(
        _ key: RemoteKeyCode,
        mode: WindowsKeyboardMode,
        intent: ParsecKeyboardMappingIntent
    ) -> RemoteKeyCode {
        guard intent == .configured, mode == .commandAsControl else {
            return key
        }
        switch key.rawValue {
        case 227: return RemoteKeyCode(rawValue: 224)
        case 231: return RemoteKeyCode(rawValue: 228)
        default: return key
        }
    }
}

enum ParsecKeyboardMappingSource: Hashable {
    case event
    case virtualToggle
}

private struct ParsecKeyboardMappingToken: Hashable {
    let source: ParsecKeyboardMappingSource
    let key: RemoteKeyCode
}

/// Latches the mapped remote code selected for each key-down so a live mode
/// change cannot send key-up for a different remote key. Physical events and
/// toggleable virtual modifiers use separate lanes to avoid overwriting each
/// other when they target the same HID usage.
struct ParsecKeyboardMappingLatch {
    private var activeMappings: [ParsecKeyboardMappingToken: RemoteKeyCode] = [:]

    var isAtRest: Bool { activeMappings.isEmpty }

    mutating func map(
        _ key: RemoteKeyCode,
        pressed: Bool,
        mode: WindowsKeyboardMode,
        intent: ParsecKeyboardMappingIntent,
        source: ParsecKeyboardMappingSource = .event
    ) -> RemoteKeyCode {
        let token = ParsecKeyboardMappingToken(source: source, key: key)
        if pressed {
            let mapped = ParsecWindowsKeyboardMapping.map(
                key,
                mode: mode,
                intent: intent
            )
            activeMappings[token] = mapped
            return mapped
        }
        if let mapped = activeMappings.removeValue(forKey: token) {
            return mapped
        }
        return ParsecWindowsKeyboardMapping.map(
            key,
            mode: mode,
            intent: intent
        )
    }

    mutating func reset() {
        activeMappings.removeAll(keepingCapacity: true)
    }
}

enum ParsecWindowsShortcutAction: String, CaseIterable, Equatable {
    case copy
    case paste
    case appSwitcher = "app-switcher"
    case startMenu = "start-menu"
    case lockWorkstation = "lock-workstation"
    case taskManager = "task-manager"
    case secureAttention = "secure-attention"
    case navigation
    case functionKeys = "function-keys"
    case layoutSwitch = "layout-switch"
}

struct ParsecWindowsShortcutDescriptor: Equatable {
    let action: ParsecWindowsShortcutAction
    let route: ParsecShortcutRoute
    let chord: [RemoteKeyCode]
    let mappingIntent: ParsecKeyboardMappingIntent
}

enum ParsecWindowsShortcutCatalog {
    static func descriptor(
        for action: ParsecWindowsShortcutAction
    ) -> ParsecWindowsShortcutDescriptor {
        let route: ParsecShortcutRoute
        let chord: [RemoteKeyCode]
        let intent: ParsecKeyboardMappingIntent
        switch action {
        case .copy:
            route = .rawHardware
            chord = [RemoteKeyCode(rawValue: 224), RemoteKeyCode(rawValue: 6)]
            intent = .configured
        case .paste:
            route = .rawHardware
            chord = [RemoteKeyCode(rawValue: 224), RemoteKeyCode(rawValue: 25)]
            intent = .configured
        case .appSwitcher:
            route = .explicitMacro
            chord = [RemoteKeyCode(rawValue: 226), RemoteKeyCode(rawValue: 43)]
            intent = .raw
        case .startMenu:
            route = .explicitMacro
            chord = [RemoteKeyCode(rawValue: 227)]
            intent = .raw
        case .lockWorkstation:
            route = .explicitMacro
            chord = [RemoteKeyCode(rawValue: 227), RemoteKeyCode(rawValue: 15)]
            intent = .raw
        case .taskManager:
            route = .explicitMacro
            chord = [
                RemoteKeyCode(rawValue: 224),
                RemoteKeyCode(rawValue: 225),
                RemoteKeyCode(rawValue: 41)
            ]
            intent = .raw
        case .secureAttention:
            route = .unavailable
            chord = []
            intent = .raw
        case .navigation, .functionKeys:
            route = .rawHardware
            chord = []
            intent = .configured
        case .layoutSwitch:
            route = .explicitMacro
            chord = [RemoteKeyCode(rawValue: 226), RemoteKeyCode(rawValue: 225)]
            intent = .raw
        }
        return ParsecWindowsShortcutDescriptor(
            action: action,
            route: route,
            chord: chord,
            mappingIntent: intent
        )
    }

    static var coverageCount: Int {
        ParsecWindowsShortcutAction.allCases.count
    }
}

enum ParsecMacShortcutAction: String, CaseIterable, Equatable {
    case copy
    case paste
    case selectAll = "select-all"
    case appSwitcher = "app-switcher"
    case spotlightOrInputSource = "spotlight-or-input-source"
    case closeWindow = "close-window"
    case newWindow = "new-window"
    case minimizeWindow = "minimize-window"
    case hideApplication = "hide-application"
    case forceQuit = "force-quit"
    case navigation
    case functionKeys = "function-keys"
    case globeKey = "globe-key"
    case ipadHomeGesture = "ipad-home-gesture"
}

enum ParsecShortcutRoute: String, Equatable {
    case rawHardware = "raw-hardware"
    case priorityCapture = "priority-capture"
    case explicitMacro = "explicit-macro"
    case unavailable
}

struct ParsecMacShortcutDescriptor: Equatable {
    let action: ParsecMacShortcutAction
    let route: ParsecShortcutRoute
    let chord: [RemoteKeyCode]
}

struct ParsecShortcutExecutionSnapshot: Equatable {
    let completedCount: UInt64
    let lastRoute: ParsecShortcutRoute?

    var digest: String {
        "completed=\(completedCount) route=\(lastRoute?.rawValue ?? "none")"
    }
}

enum ParsecMacShortcutCatalog {
    private static let command = RemoteKeyCode(rawValue: 227)
    private static let option = RemoteKeyCode(rawValue: 226)

    static func descriptor(
        for action: ParsecMacShortcutAction
    ) -> ParsecMacShortcutDescriptor {
        let route: ParsecShortcutRoute
        let chord: [RemoteKeyCode]
        switch action {
        case .copy:
            route = .priorityCapture
            chord = [command, RemoteKeyCode(rawValue: 6)]
        case .paste:
            route = .priorityCapture
            chord = [command, RemoteKeyCode(rawValue: 25)]
        case .selectAll:
            route = .priorityCapture
            chord = [command, RemoteKeyCode(rawValue: 4)]
        case .appSwitcher:
            route = .explicitMacro
            chord = [command, RemoteKeyCode(rawValue: 43)]
        case .spotlightOrInputSource:
            route = .explicitMacro
            chord = [command, RemoteKeyCode(rawValue: 44)]
        case .closeWindow:
            route = .priorityCapture
            chord = [command, RemoteKeyCode(rawValue: 26)]
        case .newWindow:
            route = .priorityCapture
            chord = [command, RemoteKeyCode(rawValue: 17)]
        case .minimizeWindow:
            route = .priorityCapture
            chord = [command, RemoteKeyCode(rawValue: 16)]
        case .hideApplication:
            route = .explicitMacro
            chord = [command, RemoteKeyCode(rawValue: 11)]
        case .forceQuit:
            route = .explicitMacro
            chord = [command, option, RemoteKeyCode(rawValue: 41)]
        case .navigation, .functionKeys:
            route = .rawHardware
            chord = []
        case .globeKey, .ipadHomeGesture:
            route = .unavailable
            chord = []
        }
        return ParsecMacShortcutDescriptor(
            action: action,
            route: route,
            chord: chord
        )
    }

    static var coverageCount: Int {
        ParsecMacShortcutAction.allCases.count
    }
}

struct ParsecPointerBehavior: Equatable {
    let mode: PointerPresentationMode
    let nativePointerActive: Bool

    var prefersPointerLocked: Bool {
        mode == .captured
    }

    var inputRoute: ParsecPointerInputRoute {
        mode == .native ? .absolute : .relative
    }

    var cursorOwner: ParsecPointerCursorOwner {
        switch mode {
        case .native:
            return nativePointerActive ? .system : .host
        case .captured:
            return .local
        }
    }

    var showsHostCursor: Bool {
        cursorOwner == .host
    }

    var showsLocalCursor: Bool {
        cursorOwner == .local
    }

    var digest: String {
        "mode=\(mode == .native ? "native" : "captured") "
            + "lock=\(prefersPointerLocked) "
            + "route=\(inputRoute.rawValue) "
            + "cursor=\(cursorOwner.rawValue)"
    }
}

enum LayoutSyncHotkey: Int, CaseIterable {
    case none = 0
    case ctrlSpace = 1
    case cmdSpace = 2
    case altSpace = 3
    case altShift = 4
    case ctrlShift = 5
}

enum RightClickPosition: Int {
    case firstFinger = 0
    case middle = 1
    case secondFinger = 2
}

struct KeyBoardKeyEvent: Equatable {
    let key: RemoteKeyCode
    let isPressBegin: Bool
    let mappingIntent: ParsecKeyboardMappingIntent

    init(
        key: RemoteKeyCode,
        isPressBegin: Bool,
        mappingIntent: ParsecKeyboardMappingIntent = .configured
    ) {
        self.key = key
        self.isPressBegin = isPressBegin
        self.mappingIntent = mappingIntent
    }
}
