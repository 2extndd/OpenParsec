import Foundation
import SwiftUI
import CoreGraphics
import GLKit

extension Notification.Name {
	static let parsecMouseInputDidChange = Notification.Name(
		"ParsecMouseInputDidChange"
	)
	static let parsecKeyboardInputDidChange = Notification.Name(
		"ParsecKeyboardInputDidChange"
	)
	static let parsecShortcutExecutionDidChange = Notification.Name(
		"ParsecShortcutExecutionDidChange"
	)
	static let parsecGamepadInputDidChange = Notification.Name(
		"ParsecGamepadInputDidChange"
	)
	static let parsecConcurrencyDiagnosticsDidChange = Notification.Name(
		"ParsecConcurrencyDiagnosticsDidChange"
	)
	static let parsecTransportRecoveryDidChange = Notification.Name(
		"ParsecTransportRecoveryDidChange"
	)
}

enum ParsecResolution: String, CaseIterable, Hashable {
	case host = "Host Resolution"
	case client = "Client Resolution" // updated dynamically during connection
	case r3840x2160_16_9 = "3840x2160 (16:9)"
	case r3840x1600_21_9 = "3840x1600 (21:9)"
	case r3440x1440_21_9 = "3440x1440 (21:9)"
	case r2560x1600_16_10 = "2560x1600 (16:10)"
	case r2560x1440_16_9 = "2560x1440 (16:9)"
	case r2560x1080_21_9 = "2560x1080 (21:9)"
	case r1920x1200_16_10 = "1920x1200 (16:10)"
	case r1920x1080_16_9 = "1920x1080 (16:9)"
	case r1680x1050_16_10 = "1680x1050 (16:10)"
	case r1600x1200_4_3 = "1600x1200 (4:3)"
	case r1366x768_16_9 = "1366x768 (16:9)"
	case r1280x1024_5_4 = "1280x1024 (5:4)"
	case r1280x800_16_10 = "1280x800 (16:10)"
	case r1280x720_16_9 = "1280x720 (16:9)"
	case r1024x768_4_3 = "1024x768 (4:3)"

	// Landscape native pixels until ParsecView reports the real content size;
	// the old (3480, 2160) placeholder was sent on the first connect each launch.
	private static var clientSize: (width: Int, height: Int) = {
		let bounds = UIScreen.main.nativeBounds
		return (Int(max(bounds.width, bounds.height)), Int(min(bounds.width, bounds.height)))
	}()

	var width: Int {
		switch self {
		case .host:
			return 0
		case .client:
			return ParsecResolution.clientSize.width
		case .r3840x2160_16_9:
			return 3840
		case .r3840x1600_21_9:
			return 3840
		case .r3440x1440_21_9:
			return 3440
		case .r2560x1600_16_10:
			return 2560
		case .r2560x1440_16_9:
			return 2560
		case .r2560x1080_21_9:
			return 2560
		case .r1920x1200_16_10:
			return 1920
		case .r1920x1080_16_9:
			return 1920
		case .r1680x1050_16_10:
			return 1680
		case .r1600x1200_4_3:
			return 1600
		case .r1366x768_16_9:
			return 1366
		case .r1280x1024_5_4:
			return 1280
		case .r1280x800_16_10:
			return 1280
		case .r1280x720_16_9:
			return 1280
		case .r1024x768_4_3:
			return 1024
		}
	}

	var height: Int {
		switch self {
		case .host:
			return 0
		case .client:
			return ParsecResolution.clientSize.height
		case .r3840x2160_16_9:
			return 2160
		case .r3840x1600_21_9:
			return 1600
		case .r3440x1440_21_9:
			return 1440
		case .r2560x1600_16_10:
			return 1600
		case .r2560x1440_16_9:
			return 1440
		case .r2560x1080_21_9:
			return 1080
		case .r1920x1200_16_10:
			return 1200
		case .r1920x1080_16_9:
			return 1080
		case .r1680x1050_16_10:
			return 1050
		case .r1600x1200_4_3:
			return 1200
		case .r1366x768_16_9:
			return 768
		case .r1280x1024_5_4:
			return 1024
		case .r1280x800_16_10:
			return 800
		case .r1280x720_16_9:
			return 720
		case .r1024x768_4_3:
			return 768
		}
	}

	var desc: String {
		return rawValue
	}

	static var resolutions: [ParsecResolution] {
		return Array(Self.allCases)
	}

	static var bitrates = [3, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50]

	static func updateClientResolution(width: Int, height: Int) {
		// Encoders need even dimensions (the view is 2421 px wide at 1.7196x).
		guard width > 1, height > 1 else { return }
		clientSize = (width & ~1, height & ~1)
	}

	/// Where a `stream`-sized frame lands when aspect-fit (letterbox/pillarbox,
	/// centred, never stretched or cropped) into `bounds` — the same placement
	/// ParsecClientGLRenderFrame uses for the dimensions given to
	/// ParsecClientSetDimensions. Unknown stream size → the whole bounds.
	static func aspectFit(_ stream: CGSize, in bounds: CGSize) -> CGRect {
		guard stream.width > 0, stream.height > 0, bounds.width > 0, bounds.height > 0 else {
			return CGRect(origin: .zero, size: bounds)
		}
		let scale = min(bounds.width / stream.width, bounds.height / stream.height)
		let size = CGSize(width: stream.width * scale, height: stream.height * scale)
		return CGRect(
			x: (bounds.width - size.width) / 2,
			y: (bounds.height - size.height) / 2,
			width: size.width,
			height: size.height
		)
	}
}


// Host operating system, derived from the case-11 video-config `hostOS` Int.
// The Int→OS encoding is NOT documented (the ParsecSDK framework headers are
// not vendored), so the mapping below is intentionally empty until the values
// are confirmed empirically. Connect to a known Mac host and a known Windows
// host and read the `hostOS=<n>` lines written by Diagnostics.note (retrievable
// via Settings → "Copy Diagnostics" or the Files app), then fill in the cases.
// Until then `from` returns .unknown and every OS-gated feature falls back to
// its manual toggle — so a wrong guess can never mis-gate behaviour.
enum HostOS: Equatable {
	case unknown
	case macos
	case windows
	case linux

	static func from(_ raw: Int) -> HostOS {
		switch raw {
		case 2:
			// Confirmed repeatedly against the physical macOS host in S16.
			return .macos
		// ponytail: Parsec can only host on Windows and macOS, so any other
		// value the host reports is Windows. The raw value is logged with
		// every config echo (`hostOS=`); confirm on the PC and narrow if a
		// Linux host ever appears.
		case 0...:
			return .windows
		default:
			return .unknown
		}
	}
}

struct MouseInfo {
	var pngCursor: Bool = false
	var mouseX:Int32 = 1
	var mouseY:Int32 = 1
	var cursorWidth = 0
	var cursorHeight = 0
	var cursorHotX = 0
	var cursorHotY = 0
	var cursorImg: CGImage?
	var cursorHidden = false
	var mousePositionRelative = false
}

protocol ParsecSessionServicing {
	var adapterKind: ParsecAdapterKind { get }
	var clientWidth: Float { get }
	var clientHeight: Float { get }
	var hostWidth: Float { get }
	var hostHeight: Float { get }
	var mouseInfo: MouseInfo { get }
	// Raw host-OS int from the case-11 video config (-1 until received). Read
	// lock-free from input threads; a plain Int load is atomic on the device.
	var hostOSValue: Int { get }
	var mediaReadiness: ParsecMediaReadiness { get }
	var mediaEvidence: ParsecMediaEvidence { get }

	func connect(_ peerID: String) -> RemoteStatus
	func disconnect()
	func getStatus() -> RemoteStatus
	func getStatusEx() -> RemoteClientStatus
	func setMuted(_ muted: Bool)
	func applyConfig()
	func sendUserData(type: ParsecUserDataType, message: Data)
	func updateHostVideoConfig()
	var isAudioKeepAliveActive: Bool { get }
	/// Pauses host video and parks the decoder across a resign-active window
	/// (see ParsecVideoSuspendPolicy). Audio keeps flowing.
	func setVideoSuspended(_ suspended: Bool)
}

extension ParsecSessionServicing {
	var isAudioKeepAliveActive: Bool { false }
	func setVideoSuspended(_ suspended: Bool) {}
}

protocol ParsecRenderingServicing {
	func setFrame(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat)
	func renderGLFrame(timeout: UInt32) -> ParsecRenderFrameResult
}

protocol ParsecInputServicing {
	func sendMouseMessage(_ button: RemoteMouseButton, _ x: Int32, _ y: Int32, _ pressed: Bool)
	func sendMouseClickMessage(_ button: RemoteMouseButton, _ pressed: Bool)
	func sendMouseDelta(_ dx: Int32, _ dy: Int32)
	func sendMousePosition(_ x: Int32, _ y: Int32)
	func sendKeyboardMessage(event: KeyBoardKeyEvent)
	func sendVirtualKeyboardInput(text: String)
	func sendGameControllerButtonMessage(controllerId: UInt32, _ button: RemoteGamepadButton, pressed: Bool)
	func sendGameControllerAxisMessage(controllerId: UInt32, _ axis: RemoteGamepadAxis, _ value: Int16)
	func sendGameControllerUnplugMessage(controllerId: UInt32)
	func sendWheelMsg(x: Int32, y: Int32)
}

protocol ParsecService: ParsecSessionServicing, ParsecRenderingServicing, ParsecInputServicing {
}

class CParsec
{
	public static var hostWidth:Float {
		return parsecImpl.hostWidth
	}
	public static var hostHeight:Float {
		return parsecImpl.hostHeight
	}
	
	public static var clientWidth:Float {
		return parsecImpl.clientWidth
	}
	public static var clientHeight:Float {
		return parsecImpl.clientHeight
	}

	public static var mouseInfo: MouseInfo {
		return parsecImpl.mouseInfo
	}

	static var isAudioKeepAliveActive: Bool {
		parsecImpl?.isAudioKeepAliveActive ?? false
	}

	static var mediaEvidence: ParsecMediaEvidence {
		parsecImpl.mediaEvidence
	}

	// Resolved host OS for feature gating. .unknown until the case-11 value
	// arrives AND the HostOS mapping is filled in from discovery.
	public static var hostOS: HostOS {
		return HostOS.from(parsecImpl?.hostOSValue ?? -1)
	}

	public static var adapterKind: ParsecAdapterKind {
		return parsecImpl?.adapterKind ?? .uninitialized
	}

	static var accessibilitySessionState: String {
		return sessionSnapshot.phase.rawValue
	}

	static var parsecImpl: ParsecService!
	static var sessionTracker = ParsecSessionTracker()
	private static let lifecycleLock = NSRecursiveLock()
	private static let mouseInputLock = NSLock()
	private static var mouseButtonLatch = ParsecMouseButtonLatch()
	private static var lastMouseReleaseReason: ParsecMouseReleaseReason = .none
	private static let keyboardInputLock = NSLock()
	private static var keyboardStateMachine = ParsecKeyboardStateMachine()
	private static let gamepadInputLock = NSLock()
	private static var gamepadStateMachine = ParsecGamepadStateMachine()
	private static let shortcutExecutionLock = NSLock()
	private static var shortcutExecutionState = ParsecShortcutExecutionSnapshot(
		completedCount: 0,
		lastRoute: nil
	)
	private static var mediaRecoveryCoordinator: ParsecMediaRecoveryCoordinator?
	private static let concurrencyLock = NSLock()
	private static var resourceLedger = ParsecResourceLedger()
	private static var transportRecoveryDiagnostics =
		ParsecTransportRecoveryMonitor().snapshot

	// Count accepted connect attempts under the same lock as the resource
	// ledger. The session tracker remains the source of generation truth.
	private static func recordConnectCycle(generation: UInt64) {
		concurrencyLock.lock()
		// Test fakes may replace the session tracker with an isolated lower
		// generation; production snapshots still use the tracker directly.
		_ = resourceLedger.advanceGeneration(to: generation)
		resourceLedger.recordConnectCycle()
		let snapshot = resourceLedger
		concurrencyLock.unlock()
		publishConcurrencyDiagnostics(snapshot)
	}

	static func recordBufferAcquired() {
		concurrencyLock.lock()
		resourceLedger.acquireBuffer()
		let snapshot = resourceLedger
		concurrencyLock.unlock()
		publishConcurrencyDiagnostics(snapshot)
	}

	static func recordBufferFreed() {
		concurrencyLock.lock()
		resourceLedger.freeBuffer()
		let snapshot = resourceLedger
		concurrencyLock.unlock()
		publishConcurrencyDiagnostics(snapshot)
	}

	static func recordTimerAdded() {
		concurrencyLock.lock()
		resourceLedger.addTimer()
		let snapshot = resourceLedger
		concurrencyLock.unlock()
		publishConcurrencyDiagnostics(snapshot)
	}

	static func recordTimerRemoved() {
		concurrencyLock.lock()
		resourceLedger.removeTimer()
		let snapshot = resourceLedger
		concurrencyLock.unlock()
		publishConcurrencyDiagnostics(snapshot)
	}

	private static func publishConcurrencyDiagnostics(_ ledger: ParsecResourceLedger) {
		NotificationCenter.default.post(
			name: .parsecConcurrencyDiagnosticsDidChange,
			object: ledger
		)
	}

	private static func publishConcurrencyDiagnostics() {
		concurrencyLock.lock()
		let ledger = resourceLedger
		concurrencyLock.unlock()
		publishConcurrencyDiagnostics(ledger)
	}

	static var transportRecoverySnapshot: ParsecTransportRecoverySnapshot {
		concurrencyLock.lock()
		defer { concurrencyLock.unlock() }
		return transportRecoveryDiagnostics
	}

	static func publishTransportRecovery(
		_ snapshot: ParsecTransportRecoverySnapshot
	) {
		concurrencyLock.lock()
		transportRecoveryDiagnostics = snapshot
		concurrencyLock.unlock()
		NotificationCenter.default.post(
			name: .parsecTransportRecoveryDidChange,
			object: snapshot
		)
	}

	// Aggregate at-rest concurrency view: current session generation, total
	// held input across mouse+keyboard+gamepad owners (must be 0 at rest), and
	// resource ownership counts. Content-free.
	static var concurrencySnapshot: ParsecConcurrencySnapshot {
		let gamepad = gamepadInputSnapshot
		let held = mouseInputSnapshot.pressedCount
			+ keyboardInputSnapshot.pressedCount
			+ gamepad.pressedCount
			+ gamepad.nonNeutralAxisCount
		concurrencyLock.lock()
		let ledger = resourceLedger
		concurrencyLock.unlock()
		return ParsecConcurrencySnapshot(
			generation: sessionSnapshot.generation,
			outstandingInput: held,
			outstandingBuffers: ledger.outstandingBuffers,
			activeTimers: ledger.activeTimers,
			activeObservers: ledger.activeObservers,
			connectCycles: ledger.connectCycles
		)
	}

	static var sessionSnapshot: ParsecSessionSnapshot {
		return sessionTracker.snapshot
	}

	static var mouseInputSnapshot: ParsecMouseInputSnapshot {
		mouseInputLock.lock()
		defer { mouseInputLock.unlock() }
		return ParsecMouseInputSnapshot(
			pressedCount: mouseButtonLatch.pressedCount,
			lastReleaseReason: lastMouseReleaseReason
		)
	}

	static var keyboardInputSnapshot: ParsecKeyboardSnapshot {
		keyboardInputLock.lock()
		defer { keyboardInputLock.unlock() }
		return keyboardStateMachine.snapshot
	}

	static var gamepadInputSnapshot: ParsecGamepadSnapshot {
		gamepadInputLock.lock()
		defer { gamepadInputLock.unlock() }
		return gamepadStateMachine.snapshot
	}

	static var shortcutExecutionSnapshot: ParsecShortcutExecutionSnapshot {
		shortcutExecutionLock.lock()
		defer { shortcutExecutionLock.unlock() }
		return shortcutExecutionState
	}

	static var mediaRecoverySnapshot: ParsecMediaRecoverySnapshot {
		mediaRecoveryCoordinator?.snapshot ?? ParsecMediaRecoverySnapshot(
			generation: sessionSnapshot.generation,
			phase: .idle,
			missing: .none,
			reconnectUsed: false,
			deadlineToken: 0
		)
	}

	static func configureMediaRecovery() {
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		guard mediaRecoveryCoordinator == nil else { return }
		mediaRecoveryCoordinator = ParsecMediaRecoveryCoordinator(
			scheduler: MainQueueMediaRecoveryScheduler(),
			softVideoDeadline: OpenParsecRuntime.mediaSoftDeadline,
			hardMediaDeadline: OpenParsecRuntime.mediaHardDeadline,
			onAction: { action in
				handleMediaRecoveryAction(action)
			}
		)
		observeMediaRecovery()
	}

	// Remember the last peer we connected to so callers like changeResolution
	// can disconnect and reconnect with a refreshed client configuration.
	// Resolution changes require a fresh connection; the in-session video
	// configuration event does not move resolution on the host.
	public static var lastConnectedPeerID: String?

	static func initialize(arguments: [String] = ProcessInfo.processInfo.arguments)
	{
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
#if targetEnvironment(simulator)
		let scenario = FakeParsecScenario.resolve(arguments: arguments)
		if let current = parsecImpl as? FakeParsecService,
		   current.scenario == scenario {
			return
		}
		guard parsecImpl == nil || [.idle, .failed, .disconnected].contains(sessionSnapshot.phase) else {
			return
		}
		parsecImpl = FakeParsecService(scenario: scenario)
#else
		guard parsecImpl == nil else { return }
		parsecImpl = ParsecSDKBridge()
#endif
	}

	static func destroy()
	{

	}

	static func connect(
		_ peerID: String,
		intent: ParsecConnectIntent = .initial
	) -> RemoteStatus
	{
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		let current = sessionSnapshot
		let hasActiveAttempt = ![.idle, .failed, .disconnected].contains(current.phase)
		if hasActiveAttempt && intent == .initial {
			return current.transportStatus == .notRunning
				? .connecting
				: current.transportStatus
		}
		if mouseInputSnapshot.pressedCount > 0 {
			releaseAllMouseButtons(reason: .reconnect)
		}
		if keyboardInputSnapshot.pressedCount > 0 {
			releaseAllKeyboardKeys(reason: .reconnect)
		}
		let gamepadSnapshot = gamepadInputSnapshot
		if gamepadSnapshot.pressedCount > 0 || gamepadSnapshot.nonNeutralAxisCount > 0 {
			releaseAllGamepadInputs(reason: .reconnect)
		}
		if hasActiveAttempt {
			ParsecBackgroundManager.shared.connectionDidEnd(
				generation: current.generation,
				reason: .reconfigure
			)
			parsecImpl.disconnect()
			lastConnectedPeerID = nil
		} else if current.phase == .failed {
			// The SDK keeps reporting its error until Disconnect; connecting on
			// top of it fails again (ALREADY_RUNNING / repeated NAT error).
			parsecImpl.disconnect()
		}
		lastConnectedPeerID = peerID
		let attempt = sessionTracker.beginConnect(intent: intent, adapter: adapterKind)
		beginKeyboardGeneration(attempt.generation)
		beginGamepadGeneration(attempt.generation)
		recordConnectCycle(generation: attempt.generation)
		ParsecBackgroundManager.shared.connectionDidStart(
			peerId: peerID,
			generation: attempt.generation
		)
		let initiationStatus = parsecImpl.connect(peerID)
		// ParsecClientConnect is asynchronous: PARSEC_OK means only that the
		// attempt was accepted, not that the transport is usable. Publishing
		// `.ok` here races generation-scoped setup (dimensions, host config,
		// render-surface replacement) against PARSEC_NOT_RUNNING. Only a later
		// GetStatus poll may advance the app-domain transport to `.ok`.
		let observedStatus: RemoteStatus = initiationStatus == .ok
			? .connecting
			: initiationStatus
		observeAdapterState(
			status: observedStatus,
			generation: attempt.generation,
			stage: intent == .reconnect ? .reconnecting : .connecting
		)
		if initiationStatus != .ok && initiationStatus != .connecting {
			ParsecBackgroundManager.shared.connectionAttemptDidFail(
				peerID: peerID,
				generation: attempt.generation,
				intent: intent
			)
			if intent != .reconnect {
				lastConnectedPeerID = nil
			}
		}
		return observedStatus
	}

	@discardableResult
	static func disconnect(
		reason: ParsecDisconnectReason = .user,
		generation: UInt64? = nil
	) -> Bool
	{
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		let observedGeneration = generation ?? sessionSnapshot.generation
		let snapshot = sessionSnapshot
		guard observedGeneration == snapshot.generation else { return false }
		guard ![.idle, .disconnected].contains(snapshot.phase) else { return false }
		guard sessionTracker.disconnect(reason: reason, generation: observedGeneration) != nil else { return false }
		Diagnostics.note("session-disconnect reason=\(reason.rawValue) generation=\(observedGeneration) phase=\(snapshot.phase.rawValue) status=\(snapshot.transportStatus.rawValue)")
		releaseAllMouseButtons(reason: .sessionDisconnected)
		releaseAllKeyboardKeys(reason: .sessionDisconnected)
		releaseAllGamepadInputs(reason: .sessionDisconnected)
		observeMediaRecovery()
		// Clear the peer-ID memo only after this caller atomically claims the
		// disconnect transition. A duplicate notification then observes the
		// terminal phase and cannot tear the adapter down a second time.
		lastConnectedPeerID = nil
		ParsecBackgroundManager.shared.connectionDidEnd(
			generation: observedGeneration,
			reason: reason
		)
		parsecImpl.disconnect()
		return true
	}

	static func enterBackground(generation: UInt64? = nil) {
		let observedGeneration = generation ?? sessionSnapshot.generation
		releaseAllMouseButtons(reason: .background)
		releaseAllKeyboardKeys(reason: .background)
		releaseAllGamepadInputs(reason: .background)
		_ = sessionTracker.enterBackground(generation: observedGeneration)
		observeMediaRecovery()
	}

	static func enterBackgroundGrace(generation: UInt64? = nil) {
		let observedGeneration = generation ?? sessionSnapshot.generation
		_ = sessionTracker.enterBackgroundGrace(generation: observedGeneration)
		observeMediaRecovery()
	}

	static func resumeForeground(generation: UInt64? = nil) {
		let observedGeneration = generation ?? sessionSnapshot.generation
		_ = sessionTracker.resumeForeground(generation: observedGeneration)
		observeMediaRecovery()
	}

	static func getStatus(generation: UInt64? = nil) -> RemoteStatus
	{
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		let observedGeneration = generation ?? sessionSnapshot.generation
		let status = parsecImpl.getStatus()
		observeAdapterState(status: status, generation: observedGeneration)
		return status
	}

    static func getStatusEx(generation: UInt64? = nil) -> RemoteClientStatus
	{
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		let observedGeneration = generation ?? sessionSnapshot.generation
		let status = parsecImpl.getStatusEx()
		observeAdapterState(status: status.status, generation: observedGeneration)
		return status
	}

	private static func observeAdapterState(
		status: RemoteStatus,
		generation: UInt64,
		stage: ParsecFailureStage = .transport
	) {
		_ = sessionTracker.observeTransport(status, generation: generation, stage: stage)
		_ = sessionTracker.observeMedia(parsecImpl.mediaReadiness, generation: generation)
		observeMediaRecovery()
	}
	
	private static func observeMediaRecovery() {
		guard let mediaRecoveryCoordinator,
		      parsecImpl != nil else { return }
		mediaRecoveryCoordinator.observe(
			sessionSnapshot,
			evidence: parsecImpl.mediaEvidence
		)
	}

	private static func handleMediaRecoveryAction(
		_ action: ParsecMediaRecoveryAction
	) {
		if case let .terminalFailure(generation, stage) = action {
			let evidence = parsecImpl?.mediaEvidence
			let observedStatus = stage == .audio
				? evidence?.audioStatus
				: evidence?.videoStatus
			let fallbackCode: Int32 = stage == .audio ? -7102 : -7101
			let status = observedStatus?.isFailure == true
				? observedStatus!
				: RemoteStatus(rawValue: fallbackCode)
			_ = sessionTracker.observeTransport(
				status,
				generation: generation,
				stage: stage
			)
			observeMediaRecovery()
		}
		NotificationCenter.default.post(
			name: .parsecMediaRecoveryActionRequested,
			object: action
		)
	}

	static func setFrame(_ width:CGFloat, _ height:CGFloat, _ scale: CGFloat )
	{
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		parsecImpl.setFrame(width, height, scale)
	}

	@discardableResult
	static func renderGLFrame(
		timeout: UInt32 = 16
	) -> ParsecRenderFrameResult {
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		let generation = sessionSnapshot.generation
		let hadVideo = parsecImpl.mediaEvidence.readiness.video
		let result = parsecImpl.renderGLFrame(timeout: timeout)
		let readiness = parsecImpl.mediaEvidence.readiness
		_ = sessionTracker.observeMedia(
			readiness,
			generation: generation
		)
		if !hadVideo && readiness.video {
			Diagnostics.note("render-media event=first-frame generation=\(generation)")
		}
		observeMediaRecovery()
		return result
	}
	
	static func setMuted(_ muted: Bool)
	{
		parsecImpl.setMuted(muted)
	}
	
	static func applyConfig()
	{
		parsecImpl.applyConfig()
	}
	
	static func updateHostVideoConfig() {
		parsecImpl.updateHostVideoConfig()
	}

	static func setVideoSuspended(_ suspended: Bool) {
		// Same lock as getStatusEx, which drives the resume recovery check.
		lifecycleLock.lock()
		defer { lifecycleLock.unlock() }
		parsecImpl.setVideoSuspended(suspended)
	}

	static func sendMouseMessage(
		_ button: RemoteMouseButton,
		_ x: Int32,
		_ y: Int32,
		_ pressed: Bool,
		releaseReason: ParsecMouseReleaseReason = .normal
	) {
		mouseInputLock.lock()
		guard mouseButtonLatch.update(button, pressed: pressed) else {
			mouseInputLock.unlock()
			return
		}
		if !pressed { lastMouseReleaseReason = releaseReason }
		parsecImpl.sendMouseMessage(button, x, y, pressed)
		let snapshot = ParsecMouseInputSnapshot(
			pressedCount: mouseButtonLatch.pressedCount,
			lastReleaseReason: lastMouseReleaseReason
		)
		mouseInputLock.unlock()
		publishMouseInput(snapshot)
	}
	
	static func sendMouseClickMessage(
		_ button: RemoteMouseButton,
		_ pressed: Bool,
		releaseReason: ParsecMouseReleaseReason = .normal
	) {
		mouseInputLock.lock()
		guard mouseButtonLatch.update(button, pressed: pressed) else {
			mouseInputLock.unlock()
			return
		}
		if !pressed { lastMouseReleaseReason = releaseReason }
		parsecImpl.sendMouseClickMessage(button, pressed)
		let snapshot = ParsecMouseInputSnapshot(
			pressedCount: mouseButtonLatch.pressedCount,
			lastReleaseReason: lastMouseReleaseReason
		)
		mouseInputLock.unlock()
		publishMouseInput(snapshot)
	}

	static func releaseAllMouseButtons(reason: ParsecMouseReleaseReason) {
		mouseInputLock.lock()
		let buttons = mouseButtonLatch.releaseAll()
		lastMouseReleaseReason = reason
		for button in buttons {
			parsecImpl?.sendMouseClickMessage(button, false)
		}
		let snapshot = ParsecMouseInputSnapshot(
			pressedCount: 0,
			lastReleaseReason: reason
		)
		mouseInputLock.unlock()
		publishMouseInput(snapshot)
	}

	private static func publishMouseInput(_ snapshot: ParsecMouseInputSnapshot) {
		NotificationCenter.default.post(
			name: .parsecMouseInputDidChange,
			object: snapshot
		)
		publishConcurrencyDiagnostics()
	}
	
	static func sendMouseDelta(_ dx: Int32, _ dy: Int32) {
		parsecImpl.sendMouseDelta(dx, dy)
	}

	static func sendMousePosition(_ x:Int32, _ y:Int32)
	{
		parsecImpl.sendMousePosition(x, y)
	}

	static func sendKeyboardMessage(
		event: KeyBoardKeyEvent,
		releaseReason: ParsecKeyboardReleaseReason = .normal
	) {
		keyboardInputLock.lock()
		let transition: ParsecKeyboardTransition
		if event.isPressBegin {
			transition = keyboardStateMachine.press(event.key)
		} else {
			transition = keyboardStateMachine.release(
				event.key,
				reason: releaseReason
			)
		}
		guard transition != .ignored else {
			keyboardInputLock.unlock()
			return
		}
		parsecImpl.sendKeyboardMessage(event: event)
		let snapshot = keyboardStateMachine.snapshot
		keyboardInputLock.unlock()
		publishKeyboardInput(snapshot)
	}

	static func releaseAllKeyboardKeys(reason: ParsecKeyboardReleaseReason) {
		keyboardInputLock.lock()
		let keys = keyboardStateMachine.releaseAll(reason: reason)
		for key in keys {
			parsecImpl?.sendKeyboardMessage(
				event: KeyBoardKeyEvent(key: key, isPressBegin: false)
			)
		}
		let snapshot = keyboardStateMachine.snapshot
		keyboardInputLock.unlock()
		publishKeyboardInput(snapshot)
	}

	private static func beginKeyboardGeneration(_ generation: UInt64) {
		keyboardInputLock.lock()
		let keys = keyboardStateMachine.beginGeneration(generation)
		for key in keys {
			parsecImpl?.sendKeyboardMessage(
				event: KeyBoardKeyEvent(key: key, isPressBegin: false)
			)
		}
		let snapshot = keyboardStateMachine.snapshot
		keyboardInputLock.unlock()
		publishKeyboardInput(snapshot)
	}

	private static func publishKeyboardInput(_ snapshot: ParsecKeyboardSnapshot) {
		NotificationCenter.default.post(
			name: .parsecKeyboardInputDidChange,
			object: snapshot
		)
		publishConcurrencyDiagnostics()
	}

	@discardableResult
	static func sendKeyboardChord(
		_ chord: [RemoteKeyCode],
		route: ParsecShortcutRoute,
		mappingIntent: ParsecKeyboardMappingIntent = .configured
	) -> Bool {
		guard !chord.isEmpty, route != .unavailable else { return false }
		var unique: [RemoteKeyCode] = []
		var seen: Set<RemoteKeyCode> = []
		for key in chord where seen.insert(key).inserted {
			unique.append(key)
		}

		keyboardInputLock.lock()
		var pressedForChord: [RemoteKeyCode] = []
		var transientRawModifiers: [RemoteKeyCode] = []
		for key in unique {
			if keyboardStateMachine.pressed.contains(key) {
				let configured = ParsecWindowsKeyboardMapping.map(
					key,
					mode: SettingsHandler.effectiveWindowsKeyboardMode,
					intent: .configured
				)
				let requested = ParsecWindowsKeyboardMapping.map(
					key,
					mode: SettingsHandler.effectiveWindowsKeyboardMode,
					intent: mappingIntent
				)
				if isKeyboardModifier(key), configured != requested {
					// The physical configured hold and this raw Windows modifier
					// represent different host keys. Emit a transient raw pair
					// without changing ownership of the physical hold.
					transientRawModifiers.append(key)
					parsecImpl.sendKeyboardMessage(
						event: KeyBoardKeyEvent(
							key: key,
							isPressBegin: true,
							mappingIntent: mappingIntent
						)
					)
				} else if !isKeyboardModifier(key) {
					_ = keyboardStateMachine.press(key)
					parsecImpl.sendKeyboardMessage(
						event: KeyBoardKeyEvent(
							key: key,
							isPressBegin: true,
							mappingIntent: mappingIntent
						)
					)
				}
				continue
			}
			_ = keyboardStateMachine.press(key)
			pressedForChord.append(key)
			parsecImpl.sendKeyboardMessage(
				event: KeyBoardKeyEvent(
					key: key,
					isPressBegin: true,
					mappingIntent: mappingIntent
				)
			)
		}
		for key in pressedForChord.reversed() {
			_ = keyboardStateMachine.release(key)
			parsecImpl.sendKeyboardMessage(
				event: KeyBoardKeyEvent(
					key: key,
					isPressBegin: false,
					mappingIntent: mappingIntent
				)
			)
		}
		for key in transientRawModifiers.reversed() {
			parsecImpl.sendKeyboardMessage(
				event: KeyBoardKeyEvent(
					key: key,
					isPressBegin: false,
					mappingIntent: mappingIntent
				)
			)
		}
		let keyboardSnapshot = keyboardStateMachine.snapshot
		keyboardInputLock.unlock()
		publishKeyboardInput(keyboardSnapshot)

		shortcutExecutionLock.lock()
		shortcutExecutionState = ParsecShortcutExecutionSnapshot(
			completedCount: shortcutExecutionState.completedCount &+ 1,
			lastRoute: route
		)
		let shortcutSnapshot = shortcutExecutionState
		shortcutExecutionLock.unlock()
		NotificationCenter.default.post(
			name: .parsecShortcutExecutionDidChange,
			object: shortcutSnapshot
		)
		return true
	}

	private static func isKeyboardModifier(_ key: RemoteKeyCode) -> Bool {
		(224...231).contains(key.rawValue)
	}

	@discardableResult
	static func sendWindowsShortcut(_ action: ParsecWindowsShortcutAction) -> Bool {
		let descriptor = ParsecWindowsShortcutCatalog.descriptor(for: action)
		return sendKeyboardChord(
			descriptor.chord,
			route: descriptor.route,
			mappingIntent: descriptor.mappingIntent
		)
	}

	@discardableResult
	static func sendMacShortcut(
		_ action: ParsecMacShortcutAction,
		route overrideRoute: ParsecShortcutRoute? = nil
	) -> Bool {
		let descriptor = ParsecMacShortcutCatalog.descriptor(for: action)
		return sendKeyboardChord(
			descriptor.chord,
			route: overrideRoute ?? descriptor.route
		)
	}
	
	static func sendVirtualKeyboardInput(text: String) {
		guard !text.isEmpty else { return }
		if KeyCodeTranslators.parsecKeyCodeTranslator(text) != nil || text.count == 1 {
			parsecImpl.sendVirtualKeyboardInput(text: text)
			return
		}
		// UIKit may deliver paste/composition as more than one character. The
		// adapter emits a bounded press/release tap for each character.
		for character in text {
			parsecImpl.sendVirtualKeyboardInput(text: String(character))
		}
	}
	
	static func sendVirtualKeyboardInput(text: String, isOn: Bool) {
		guard let key = KeyCodeTranslators.parsecKeyCodeTranslator(text) else { return }
		sendKeyboardMessage(
			event: KeyBoardKeyEvent(key: key, isPressBegin: isOn)
		)
	}
	
	static func sendGameControllerButtonMessage(controllerId: UInt32, _ button:RemoteGamepadButton, pressed: Bool)
	{
		gamepadInputLock.lock()
		let transition = gamepadStateMachine.button(
			button,
			pressed: pressed,
			controllerId: controllerId
		)
		guard transition != .ignored else {
			let snapshot = gamepadStateMachine.snapshot
			gamepadInputLock.unlock()
			publishGamepadInput(snapshot)
			return
		}
		parsecImpl.sendGameControllerButtonMessage(controllerId: controllerId, button, pressed: pressed)
		let snapshot = gamepadStateMachine.snapshot
		gamepadInputLock.unlock()
		publishGamepadInput(snapshot)
	}
	
	
	static func sendGameControllerAxisMessage(controllerId: UInt32, _ axis:RemoteGamepadAxis, _ value: Int16)
	{
		gamepadInputLock.lock()
		gamepadStateMachine.axis(axis, value: value, controllerId: controllerId)
		parsecImpl.sendGameControllerAxisMessage(controllerId: controllerId, axis, value)
		let snapshot = gamepadStateMachine.snapshot
		gamepadInputLock.unlock()
		publishGamepadInput(snapshot)
	}
	
	static func sendGameControllerUnplugMessage(controllerId: UInt32)
	{
		gamepadInputLock.lock()
		let released = gamepadStateMachine.releaseController(controllerId)
		for button in released.buttons {
			parsecImpl?.sendGameControllerButtonMessage(controllerId: controllerId, button, pressed: false)
		}
		for axis in released.axes {
			parsecImpl?.sendGameControllerAxisMessage(controllerId: controllerId, axis, 0)
		}
		parsecImpl.sendGameControllerUnplugMessage(controllerId: controllerId)
		let snapshot = gamepadStateMachine.snapshot
		gamepadInputLock.unlock()
		publishGamepadInput(snapshot)
	}

	/// Releases every held gamepad button (to false) and neutralizes every
	/// non-neutral axis (to 0) across all controllers, then publishes a
	/// snapshot. Called at every lifecycle boundary alongside the mouse and
	/// keyboard release so a controller cannot leave a stuck button or a
	/// deflected stick on the host across background, disconnect, or reconnect.
	static func releaseAllGamepadInputs(reason: ParsecGamepadReleaseReason) {
		gamepadInputLock.lock()
		let released = gamepadStateMachine.releaseAll(reason: reason)
		for (controllerId, button) in released.buttons {
			parsecImpl?.sendGameControllerButtonMessage(controllerId: controllerId, button, pressed: false)
		}
		for (controllerId, axis) in released.axes {
			parsecImpl?.sendGameControllerAxisMessage(controllerId: controllerId, axis, 0)
		}
		let snapshot = gamepadStateMachine.snapshot
		gamepadInputLock.unlock()
		publishGamepadInput(snapshot)
	}

	private static func beginGamepadGeneration(_ generation: UInt64) {
		gamepadInputLock.lock()
		let released = gamepadStateMachine.beginGeneration(generation)
		for (controllerId, button) in released.buttons {
			parsecImpl?.sendGameControllerButtonMessage(controllerId: controllerId, button, pressed: false)
		}
		for (controllerId, axis) in released.axes {
			parsecImpl?.sendGameControllerAxisMessage(controllerId: controllerId, axis, 0)
		}
		let snapshot = gamepadStateMachine.snapshot
		gamepadInputLock.unlock()
		publishGamepadInput(snapshot)
	}

	private static func publishGamepadInput(_ snapshot: ParsecGamepadSnapshot) {
		NotificationCenter.default.post(
			name: .parsecGamepadInputDidChange,
			object: snapshot
		)
		publishConcurrencyDiagnostics()
	}
	
	static func sendWheelMsg(x: Int32, y: Int32) {
		parsecImpl.sendWheelMsg(x: x, y: y)
	}
	
	static func sendUserData(type: ParsecUserDataType, message: Data) {
		parsecImpl.sendUserData(type: type, message: message)
	}
	
	static func getImpl() -> ParsecService {
		return parsecImpl
	}
}

/// Owns one connect sequence: connect, poll status once per 250 ms, and retry
/// transient network failures with a short backoff before reporting. -6013
/// ("UDP blocked") and other NAT/WS codes typically appear when a connect
/// races the iPad's network coming back after the app returns to foreground;
/// a quick retry succeeds where the single old attempt surfaced an alert.
/// Lives outside SwiftUI so a reconnect started while MainView is off screen
/// still completes.
final class ParsecConnectRunner {
	static let shared = ParsecConnectRunner()
	static let retryDelays: [TimeInterval] = [0.5, 1, 2, 3, 5]
	// Restoring a dropped session waits longer (~33 s): a VPN in China often
	// takes 10–30 s to re-establish, and the alternative is a dead session.
	static let reconnectRetryDelays: [TimeInterval] = [0.5, 1, 2, 3, 5, 8, 13]

	static func retryDelay(index: Int, intent: ParsecConnectIntent) -> TimeInterval? {
		let delays = intent == .reconnect ? reconnectRetryDelays : retryDelays
		return index < delays.count ? delays[index] : nil
	}

	private var timer: Timer?
	private var pendingRetry: DispatchWorkItem?
	private var sequence: UInt64 = 0

	static func isTransient(_ status: RemoteStatus) -> Bool {
		let code = status.rawValue
		// Integrity / malformed message / shutdown / unsupported won't heal.
		if [-6025, -6106, -12017, -12018].contains(code) { return false }
		return (-6999 ... -6000).contains(code)      // NAT / signalling (-6013, -6023, -6101 …)
			|| [-3002, -3003, -3009].contains(code)    // websocket read/write/going-away
			|| (-12999 ... -12000).contains(code)      // network interrupted / timeouts
	}

	var isRunning: Bool { timer != nil || pendingRetry != nil }

	/// `completion` runs on main with the final status (.ok or a failure).
	func start(
		peerID: String,
		intent: ParsecConnectIntent,
		completion: @escaping (RemoteStatus) -> Void
	) {
		cancel()
		attempt(peerID: peerID, intent: intent, index: 0, sequence: sequence, startedAt: Date(), completion: completion)
	}

	func cancel() {
		sequence &+= 1
		timer?.invalidate()
		timer = nil
		pendingRetry?.cancel()
		pendingRetry = nil
	}

	private func attempt(
		peerID: String,
		intent: ParsecConnectIntent,
		index: Int,
		sequence seq: UInt64,
		startedAt: Date,
		completion: @escaping (RemoteStatus) -> Void
	) {
		pendingRetry = nil
		let initial = CParsec.connect(peerID, intent: intent)
		let generation = CParsec.sessionSnapshot.generation
		Diagnostics.note("connect-attempt generation=\(generation) intent=\(intent) try=\(index) initial=\(initial.rawValue) app=\(UIApplication.shared.applicationState.rawValue) \(NetworkPathObserver.digest)")
		timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
			guard let self, self.sequence == seq else { t.invalidate(); return }
			// A connect that failed outright reports its real code; polling
			// would only return -3 (not running) and hide it.
			let status = initial.isFailure ? initial : CParsec.getStatus(generation: generation)
			guard CParsec.sessionSnapshot.generation == generation else {
				t.invalidate()
				self.timer = nil
				return
			}
			// CONNECTING and positive warnings (6 = waiting for host approval) are progress.
			if status != .ok && !status.isFailure && !status.endsSession { return }
			t.invalidate()
			self.timer = nil
			let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
			if status == .ok {
				Diagnostics.note("connect-ok generation=\(generation) try=\(index) elapsed=\(elapsed)s")
				completion(status)
				return
			}
			Diagnostics.note("connect-failed generation=\(generation) intent=\(intent) try=\(index) status=\(status.rawValue) elapsed=\(elapsed)s transient=\(Self.isTransient(status)) \(NetworkPathObserver.digest)")
			// Clear the SDK error state and stop poll threads before retrying or reporting.
			CParsec.disconnect(reason: .reconfigure, generation: generation)
			guard Self.isTransient(status), !status.endsSession,
				  let delay = Self.retryDelay(index: index, intent: intent) else {
				completion(status)
				return
			}
			let work = DispatchWorkItem { [weak self] in
				guard let self, self.sequence == seq else { return }
				self.attempt(peerID: peerID, intent: intent, index: index + 1, sequence: seq, startedAt: startedAt, completion: completion)
			}
			self.pendingRetry = work
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		}
	}
}
