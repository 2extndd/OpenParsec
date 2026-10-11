#if !targetEnvironment(simulator)
import ParsecSDK
import MetalKit
import AVFoundation
import UIKit
import os

private extension RemoteStatus {
    init(_ status: ParsecStatus) {
        self.init(rawValue: Int32(status.rawValue))
    }
}

class ParsecSDKBridge: ParsecService
{
	let adapterKind: ParsecAdapterKind = .real
	var hostWidth: Float = 1920
	
	var hostHeight: Float = 1080
	
	
	static let PARSEC_VER: UInt32 = UInt32((PARSEC_VER_MAJOR << 16) | PARSEC_VER_MINOR)
	
	private var _parsec: OpaquePointer!
	private var _audio: OpaquePointer!
	private let _audioPtr: UnsafeRawPointer
	private var audioWanted = false
	private let virtualKeyQueue = DispatchQueue(label: "openparsec.virtual-key-taps")
	private let audioSessionQueue = DispatchQueue(label: "openparsec.audio-session")
	private var audioObservers: [NSObjectProtocol] = []
	
	private var isVirtualShiftOn = false

	public var clientWidth: Float = 1920
	public var clientHeight: Float = 1080

	public var netProtocol: Int32 = 1
	public var mediaContainer: Int32 = 0
	public var pngCursor: Bool = false
	// See ParsecVideoSuspendPolicy. Guarded by CParsec.lifecycleLock.
	private var videoSuspended = false
	private var decoderFlipped = false
	private var streamStopped = false
	private var videoResume: (at: CFAbsoluteTime, decodeLatency: Float, nudged: Bool)?
	// Pollers and the input gate share one condition. A reconnect must drain
	// both SDK poll calls before ParsecClientDisconnect and cannot start a new
	// pair until ParsecClientConnect has accepted the replacement session.
	private let pollCondition = NSCondition()
	private var isPolling = false
	private var pollGeneration: UInt64 = 0
	// Serialises input sends with ParsecClientDisconnect: a send that passed
	// the polling check must finish before the client is torn down (the SDK
	// makes no thread-safety promise for that overlap).
	private let sendGate = NSLock()

	@discardableResult
	private func sendGated(_ message: inout ParsecMessage) -> ParsecStatus {
		sendGate.lock()
		defer { sendGate.unlock() }
		guard backgroundTaskRunning else { return PARSEC_NOT_RUNNING }
		return ParsecClientSendMessage(_parsec, &message)
	}
	private var activePollerCount = 0
	private var backgroundTaskRunning: Bool {
		pollCondition.lock()
		defer { pollCondition.unlock() }
		return isPolling
	}
	var didSetResolution = false
	// Restored once per session in handleUserDataEvent case 12 so display
	// hot-plug / sleep-wake echoes don't keep re-firing updateHostVideoConfig
	// and causing momentary re-encode flicker.
	var didRestoreSavedDisplay = false
	
	// C1 fix: `mouseInfo` is written on the poll thread (handleCursorEvent),
	// on the input paths (sendMousePosition / setFrame), and read on the main
	// thread (updateImage). It holds a `CGImage?` (`cursorImg`) — an ARC
	// reference. A struct copy in the getter retains `cursorImg` while a
	// concurrent write releases it; that non-atomic retain/release races and
	// over-releases the CGImage → use-after-free crash that fires constantly
	// during cursor motion. All access now goes through `os_unfair_lock`:
	// readers take an atomic snapshot via the `mouseInfo` getter, writers
	// mutate under the same lock via `withMouseInfo`.
	private var _mouseInfo = MouseInfo()
	private var mouseInfoLock = os_unfair_lock_s()
	private var _mediaEvidence = ParsecMediaEvidence.initial
	private var mediaEvidenceLock = os_unfair_lock_s()
	private let keyboardMappingLock = NSLock()
	private var keyboardMappingLatch = ParsecKeyboardMappingLatch()

	// S04: raw host-OS int mirror, written from the case-11 main block and read
	// lock-free from input threads (plain Int load is atomic on-device). Reset
	// to -1 on connect AND disconnect so a stale value can't bleed across a
	// host switch. -1 = unknown / not yet received.
	var hostOSValue: Int = -1

	// S06: monotonic token bumped per updateHostVideoConfig() so a superseded
	// resend/echo-request from an earlier call drops instead of stacking timers
	// and re-confirming a stale value. Plus the user-owned fields awaiting host
	// confirmation: while set, a case-11 echo CONFIRMS (clears) on match but
	// must never clobber the user's in-flight bitrate/fps selection with a
	// stale echoed value — that was the "checkmark jumps back" bug. Touched on
	// the main thread (all callers are main); the resend closures only read the
	// token (benign plain-Int read, same pattern as backgroundTaskRunning).
	private var configRevision: Int = 0
	private var pendingUserConfig: (bitrate: Int, constantFps: Bool)? = nil
	// The display id a switch is still trying to land. A single fire-and-forget
	// setVideoConfig can be dropped while the host encoder is mid-reset from the
	// switch — the reason a display change historically needed two or three taps
	// (and why "select the current monitor, then the target" worked: it spaced
	// two sends by a human delay). We keep re-asserting this output on a widening
	// schedule until the case-11 echo reports it as the host's current output, or
	// we hit the attempt cap. Cleared on the main thread; the retry closures read
	// it lock-free (same benign-plain-read pattern as pendingUserConfig).
	private var pendingOutput: String? = nil
	// Output the host last echoed (main thread). Bitrate/FPS pushes still
	// carry `output`, but only a real change runs the confirm/retry loop.
	private var hostOutput: String? = nil
	private var pendingOutputSince = Date() // diagnostics: switch→confirm latency
	// Peer of the last connect(); a different host invalidates model.output.
	private var lastSessionPeerID: String? = nil

	// Atomic snapshot for cross-thread readers. Returns a consistent copy of
	// the whole struct under the lock so `cursorImg`'s retain happens while no
	// writer can release it.
	var mouseInfo: MouseInfo {
		os_unfair_lock_lock(&mouseInfoLock)
		defer { os_unfair_lock_unlock(&mouseInfoLock) }
		return _mouseInfo
	}

	// Serialize every mutation under the same lock the snapshot getter uses.
	// Keep the body short — never do heavy work (e.g. CGImage construction)
	// while holding the lock; build first, then assign inside.
	@discardableResult
	private func withMouseInfo<T>(_ body: (inout MouseInfo) -> T) -> T {
		os_unfair_lock_lock(&mouseInfoLock)
		defer { os_unfair_lock_unlock(&mouseInfoLock) }
		return body(&_mouseInfo)
	}

	var mediaEvidence: ParsecMediaEvidence {
		os_unfair_lock_lock(&mediaEvidenceLock)
		defer { os_unfair_lock_unlock(&mediaEvidenceLock) }
		return _mediaEvidence
	}

	var mediaReadiness: ParsecMediaReadiness {
		mediaEvidence.readiness
	}

	private func updateMediaEvidence(_ body: (inout ParsecMediaEvidence) -> Void) {
		os_unfair_lock_lock(&mediaEvidenceLock)
		defer { os_unfair_lock_unlock(&mediaEvidenceLock) }
		body(&_mediaEvidence)
	}

	private func resetMediaReadiness() {
		updateMediaEvidence { $0 = .initial }
	}

	init() {
		print("Parsec SDK Version: " + String(ParsecSDKBridge.PARSEC_VER))
		
		// The SDK log is the only source that explains NAT/-60xx failures, so
		// persist non-debug lines to diagnostics instead of stdout only.
		ParsecSetLogCallback(
			{ (level, msg, opaque) in
				guard let msg else { return }
				let line = String(cString: msg)
				if level == LOG_DEBUG { print("[D] \(line)"); return }
				Diagnostics.note("sdk-log \(line)")
			}, nil)
		
		audio_init(&_audio)
		
		self._audioPtr = UnsafeRawPointer(_audio)
		
		// ParsecInit reads `reserved` as a NUL-terminated C string; the old
		// JSONEncoder bytes had no terminator, so the SDK read past the buffer.
		let initStatus = "{\"ssHost\":\"kessel-ws.parsec.app\"}".withCString {
			ParsecInit(ParsecSDKBridge.PARSEC_VER, nil, $0, &_parsec)
		}
		Diagnostics.note("sdk-init result=\(initStatus.rawValue)")

		// The system stops the AudioQueue on interruptions and invalidates it on a
		// media-services reset; a silent host sends no packets to trigger the lazy
		// restart in audio_cb, so re-arm explicitly at these points.
		let center = NotificationCenter.default
		for name in [AVAudioSession.interruptionNotification,
					 AVAudioSession.mediaServicesWereResetNotification,
					 UIApplication.didBecomeActiveNotification] {
			audioObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
				guard let self, self.audioWanted else { return }
				if note.name == AVAudioSession.interruptionNotification,
				   (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.ended.rawValue {
					return
				}
				Diagnostics.note("audio-rearm reason=\(note.name.rawValue)")
				if note.name == AVAudioSession.mediaServicesWereResetNotification {
					audio_clear(&self._audio)
				}
				self.activateAudio()
			})
		}

	}
	
	deinit {
		stopBackgroundTaskAndWait()
		ParsecDestroy(_parsec)
		audio_destroy(&_audio)
	}
	
	func connect(_ peerID: String) -> RemoteStatus {
		resetMediaReadiness()
		hostOutput = nil
		// Every fresh connect() should attempt to restore the saved display
		// when case-12 arrives. Resetting here (not only in disconnect()) is
		// load-bearing — common reconnect paths (alert dismiss → reconnect,
		// background → resume) skip disconnect() entirely, so without this
		// the flag stayed `true` from a prior session and the restore was
		// silently never re-run.
		didRestoreSavedDisplay = false
		didSetResolution = false
		hostOSValue = -1
		DispatchQueue.main.async { DataManager.model.hostOS = -1 }
		// DataManager.model outlives sessions. Another host's display id/list
		// must not ride the first-echo push (host would capture a missing
		// output → black screen, then retry for ~5 s waiting on a confirm).
		// Also when session choices aren't remembered: a reconnect must not
		// re-push the previous display switch.
		if peerID != lastSessionPeerID || !SettingsHandler.saveSessionSettings {
			lastSessionPeerID = peerID
			DispatchQueue.main.async {
				DataManager.model.output = "none"
				DataManager.model.hostOutput = "none"
				DataManager.model.displayConfigs = []
			}
		}

		// A new decode_thread starts with a fresh decoder and an unpaused host.
		videoSuspended = false
		streamStopped = false
		decoderFlipped = false
		videoResume = nil

		var parsecClientCfg = ParsecClientConfig()
		parsecClientCfg.video.0.decoderIndex = 1
        // Use saved resolution from SettingsHandler
		parsecClientCfg.video.0.resolutionX = Int32(SettingsHandler.resolution.width)
		parsecClientCfg.video.0.resolutionY = Int32(SettingsHandler.resolution.height)
		parsecClientCfg.video.0.decoderCompatibility = SettingsHandler.decoderCompatibility
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = Int32(SettingsHandler.resolution.width)
		parsecClientCfg.video.1.resolutionY = Int32(SettingsHandler.resolution.height)
		parsecClientCfg.video.1.decoderCompatibility = SettingsHandler.decoderCompatibility
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = 0
		parsecClientCfg.protocol = 1
		//parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = false

		let status = ParsecClientConnect(_parsec, &parsecClientCfg, NetworkHandler.clinfo?.session_id, peerID)
		let remoteStatus = RemoteStatus(status)
		if remoteStatus == .ok || remoteStatus == .connecting {
			startBackgroundTask()
			audioWanted = true
			activateAudio()
		}
		return remoteStatus
	}
	
	func disconnect() {

		resetMediaReadiness()
		videoResume = nil
		stopBackgroundTaskAndWait()
		audioWanted = false
		// setActive can block 10–100+ ms: off the main thread, on the same
		// serial queue as activateAudio() so a quick reconnect's activation
		// always lands after this deactivation.
		// Clear on the same queue too: a pending activateAudio() (setActive can
		// be slow) must not recreate the queue after this clear and keep a
		// silent player alive after the session ended.
		let audio = _audioPtr
		audioSessionQueue.async {
			var ctx: OpaquePointer? = OpaquePointer(audio)
			audio_clear(&ctx)
			try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		}
		// Waits for any input send that passed its gate before polling stopped.
		sendGate.lock()
		ParsecClientDisconnect(_parsec)
		sendGate.unlock()
		keyboardMappingLock.lock()
		keyboardMappingLatch.reset()
		keyboardMappingLock.unlock()
		// Reset so the next case-11 echo after a reconnect re-pushes our
		// desired resolution instead of clobbering it with whatever the host
		// happens to advertise.
		didSetResolution = false
		didRestoreSavedDisplay = false
		hostOSValue = -1
		DispatchQueue.main.async { DataManager.model.hostOS = -1 }

	}

	func getStatus() -> RemoteStatus {
		return RemoteStatus(ParsecClientGetStatus(_parsec, nil))
	}

	func getStatusEx() -> RemoteClientStatus {
		var sdkStatus = ParsecClientStatus()
		let result = ParsecClientGetStatus(_parsec, &sdkStatus)
		let decoder = sdkStatus.decoder.0
		let metrics = sdkStatus.`self`.metrics.0
		self.hostHeight = Float(decoder.height)
		self.hostWidth = Float(decoder.width)

		return RemoteClientStatus(
			status: checkVideoResume(RemoteStatus(result), decodeLatency: metrics.decodeLatency, rttMs: metrics.networkLatency),
			metrics: RemoteClientMetrics(
				decodeLatency: Double(metrics.decodeLatency),
				encodeLatency: Double(metrics.encodeLatency),
				networkLatency: Double(metrics.networkLatency),
				bitrate: Double(metrics.bitrate),
				queuedFrames: metrics.queuedFrames,
				fastRetransmits: metrics.fastRTs,
				slowRetransmits: metrics.slowRTs
			),
			decoder: RemoteDecoderStatus(
				name: String.fromBuffer(&sdkStatus.decoder.0.name.0, length: 16),
				width: decoder.width,
				height: decoder.height,
				usesH265: decoder.h265,
				usesColor444: decoder.color444
			)
		)
	}
	
	func setFrame(_ width:CGFloat, _ height:CGFloat, _ scale: CGFloat) {
		let sdkStatus = ParsecClientSetDimensions(
			_parsec,
			UInt8(DEFAULT_STREAM),
			UInt32(width),
			UInt32(height),
			Float(scale)
		)
		// Successful calls are summarised once per settled change by
		// ParsecViewController ("render-geometry event=settled").
		if sdkStatus != PARSEC_OK {
			Diagnostics.note(
				"sdk-dimensions result=\(RemoteStatus(sdkStatus).rawValue) " +
				"width=\(Int(width)) height=\(Int(height)) scale=\(scale)"
			)
		}

		clientWidth = Float(width)
		clientHeight = Float(height)
		withMouseInfo {
			$0.mouseX = Int32(width / 2)
			$0.mouseY = Int32(height / 2)
		}
	}
	
	// timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	func renderGLFrame(timeout: UInt32 = 16) -> ParsecRenderFrameResult {
		let sdkStatus = ParsecClientGLRenderFrame(
			_parsec,
			UInt8(DEFAULT_STREAM),
			nil, // pre-render fires on re-draws too: no new-frame signal (RenderClock)
			nil,
			timeout
		)
		let status = RemoteStatus(sdkStatus)
		let producedFrame = sdkStatus == PARSEC_OK
		updateMediaEvidence {
			$0.videoStatus = status
			if producedFrame {
				$0.readiness.video = true
			}
		}
		return producedFrame
			? .produced(status: status)
			: .noFrame(status: status)
	}
	
	/*static func renderMetalFrame(_ queue:inout MTLCommandQueue, _ texturePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>, timeout: UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	 {
	 ParsecClientMetalRenderFrame(_parsec, UInt8(DEFAULT_STREAM), &queue, texturePtr, nil, nil, timeout)
	 }*/
	
	func pollAudio(timeout: UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	{
		let sdkStatus = ParsecClientPollAudio(_parsec, audio_cb, timeout, _audioPtr)
		let status = RemoteStatus(sdkStatus)
		updateMediaEvidence {
			$0.audioStatus = status
			if sdkStatus == PARSEC_OK {
				$0.readiness.audio = true
			}
		}
	}
	
	var getFirstCursor = false
	var mousePositionRelative = false
	
	func pollEvent(timeout: UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	{
		var e: ParsecClientEvent!
		var _event = ParsecClientEvent()
		var pollSuccess = false;
		withUnsafeMutablePointer(to: &_event, {(_eventPtr) in
			pollSuccess = ParsecClientPollEvents(_parsec, timeout, _eventPtr)
			e = _eventPtr.pointee
		})
		if !pollSuccess {
			return
		}
		if e.type == CLIENT_EVENT_CURSOR {
			handleCursorEvent(event: e.cursor)
		} else if e.type == CLIENT_EVENT_USER_DATA {
			handleUserDataEvent(event: e.userData)
		}
	}
	
	func handleUserDataEvent(event: ParsecClientUserDataEvent) {
		
		let pointer = ParsecGetBuffer(_parsec, event.key)
		// Guard a null buffer the same way handleCursorEvent does. Without this
		// the decode paths below would crash the event poll thread on a null get;
		// there is also nothing to ParsecFree.
		guard let pointer else {
			return
		}
		CParsec.recordBufferAcquired()
		defer {
			ParsecFree(pointer)
			CParsec.recordBufferFreed()
		}
		switch event.id {
		case 11:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(ParsecUserDataVideoConfig.self, from: Data(bytesNoCopy: pointer, count: strlen(pointer), deallocator: .none))
				guard let videoConfig = config.video.first else { return }

				DispatchQueue.main.async {
					self.hostOutput = videoConfig.output
					DataManager.model.hostOutput = videoConfig.output
					Diagnostics.note(
						"video-config event=echo output=\(videoConfig.output) bitrate=\(videoConfig.encoderMaxBitrate) " +
						"fullFPS=\(videoConfig.fullFPS) res=\(videoConfig.resolutionX)x\(videoConfig.resolutionY) " +
						"pendingOutput=\(self.pendingOutput ?? "-") pendingUser=\(self.pendingUserConfig.map { "\($0.bitrate)/\($0.constantFps)" } ?? "-")"
					)
					// resolutionX/Y are host-authoritative — always adopt.
					DataManager.model.resolutionX = videoConfig.resolutionX
					DataManager.model.resolutionY = videoConfig.resolutionY
					// S06: bitrate/constantFps are user-owned. If a user change
					// is in flight, the echo only CONFIRMS (clears pending on a
					// match) — it must not overwrite the user's selection with a
					// stale value, which made the menu checkmark jump back. With
					// nothing pending, adopt the host's reported values.
					if let pending = self.pendingUserConfig {
						if videoConfig.encoderMaxBitrate == pending.bitrate
							&& videoConfig.fullFPS == pending.constantFps {
							self.pendingUserConfig = nil
						}
					} else {
						DataManager.model.bitrate = videoConfig.encoderMaxBitrate
						// Not on a session's first echo: that fullFPS is the host
						// default, and adopting it wiped the restored/in-session
						// Constant FPS right before the one-shot push below sent it.
						if self.didSetResolution { DataManager.model.constantFps = videoConfig.fullFPS }
					}
					// Confirm a display switch: once the host echoes the output we
					// asked for, stop re-asserting it. We only READ the echoed
					// output here (never write it back into model.output) so a
					// host that omits/normalizes the field can't clobber the
					// user's selection — same caution as the bitrate guard above.
					if let pendingOut = self.pendingOutput, videoConfig.output == pendingOut {
						self.pendingOutput = nil
						Diagnostics.note("display-output event=confirmed output=\(pendingOut) ms=\(Int(Date().timeIntervalSince(self.pendingOutputSince) * 1000))")
						NotificationCenter.default.post(
							name: .parsecDisplayOutputDidConfirm,
							object: nil
						)
					}
					// S04: capture the host-OS int and log it once per session
					// change so its undocumented encoding can be discovered
					// against known Mac/Windows hosts.
					if self.hostOSValue != videoConfig.hostOS {
						self.hostOSValue = videoConfig.hostOS
						DataManager.model.hostOS = videoConfig.hostOS
						Diagnostics.note("hostOS=\(videoConfig.hostOS) (resolution=\(videoConfig.resolutionX)x\(videoConfig.resolutionY), bitrate=\(videoConfig.encoderMaxBitrate))")
						// The shortcut toolbar is built once; rebuild it for the
						// now-known host (Automatic shows Mac or Windows keys).
						SettingsHandler.notifyChanged(.hostShortcutToolbarMode)
					}
					if !self.didSetResolution {
						self.didSetResolution = true
						DataManager.model.resolutionX = SettingsHandler.resolution.width
						DataManager.model.resolutionY = SettingsHandler.resolution.height
						// S08: apply the poor-network bitrate cap on the same
						// first echo that pushes the saved resolution. Bitrate
						// only reaches the host via updateHostVideoConfig (the
						// connect-time SDK config carries no encoderMaxBitrate),
						// and the case-11 branch above otherwise adopts the
						// host's bitrate — so without this the profile's cap
						// would never take effect. Riding the existing one-shot
						// push avoids a separate timer/race and leaves `output`
						// untouched, so it can't clobber the restored display.
						if SettingsHandler.bitrate > 0 {
							DataManager.model.bitrate = SettingsHandler.bitrate
							Diagnostics.note("setting-apply id=bitrate mode=reconnect result=applied")
						}
						self.updateHostVideoConfig()
					}
				}
				
			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		case 12:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(Array<ParsecDisplayConfig>.self, from: Data(bytesNoCopy: pointer, count: strlen(pointer), deallocator: .none))
				DispatchQueue.main.async {
					DataManager.model.displayConfigs = config
					Diagnostics.note("display-list count=\(config.count) ids=\(config.map(\.id).joined(separator: ","))")
					// A selection that isn't on this host (other host's id, or a
					// display unplugged since) would be re-sent by every later
					// bitrate/fps push and make the host capture a missing output.
					let current = DataManager.model.output
					if current != "none", !config.contains(where: { $0.id == current }) {
						DataManager.model.output = "none"
						self.pendingOutput = nil // stop re-asserting the missing id
						Diagnostics.note("display-output event=stale-reset")
					}
					// Restore the saved display ONCE per session. The host
					// can re-advertise its display list multiple times mid-
					// stream (sleep/wake, display hot-plug); without this
					// gate, every echo would re-fire updateHostVideoConfig
					// and cause a brief re-encode flicker.
					if !self.didRestoreSavedDisplay {
						self.didRestoreSavedDisplay = true
						let savedId = SettingsHandler.savedDisplayOutput
						let savedName = SettingsHandler.savedDisplayName
						guard SettingsHandler.saveSessionSettings,
							  !savedId.isEmpty || !savedName.isEmpty else { return }
						if let match = ParsecDisplayConfig.restoreMatch(in: config, savedId: savedId, savedName: savedName) {
							Diagnostics.note("display-output event=restore result=matched rolled=\(match.id != savedId)")
							DataManager.model.output = match.id
							SettingsHandler.savedDisplayOutput = match.id // re-sync if id rolled
							// Already streaming it (first-echo push carried it): no
							// second push → no second encoder restart at start.
							if match.id != self.hostOutput { self.updateHostVideoConfig() }
						} else {
							Diagnostics.note("display-output event=restore result=no-match")
						}
					}
				}
			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		default:
			break
		}
		
	}
	
	func handleCursorEvent(event: ParsecClientCursorEvent) {
		// hidden / relative always track the latest event; capture the prior
		// hidden state in the same locked section to decide the reposition.
		let prevHidden = withMouseInfo { info -> Bool in
			let prev = info.cursorHidden
			info.cursorHidden = event.cursor.hidden
			info.mousePositionRelative = event.cursor.relative
			return prev
		}

		guard event.cursor.imageUpdate || !getFirstCursor else { return }
		getFirstCursor = true

		let pointer = ParsecGetBuffer(_parsec, event.key)
		guard let pointer else {
			return
		}
		CParsec.recordBufferAcquired()
		defer {
			ParsecFree(pointer)
			CParsec.recordBufferFreed()
		}

		let size = event.cursor.size
		let width = event.cursor.width
		let height = event.cursor.height
		// Host-supplied sizes: never read past the buffer the SDK gave us.
		guard Int(size) >= Int(width) * Int(height) * 4 else { return }

		// Build the CGImage BEFORE taking the lock — image construction is the
		// expensive part and must not run while the snapshot getter is blocked.
		let elmentLength: Int = 4
		let render: CGColorRenderingIntent = CGColorRenderingIntent.defaultIntent
		let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
		let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
		let providerRef: CGDataProvider? = CGDataProvider(data: NSData(bytes: pointer, length: Int(size)))
		let cgimage: CGImage? = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * elmentLength, space: rgbColorSpace, bitmapInfo: bitmapInfo, provider: providerRef!, decode: nil, shouldInterpolate: true, intent: render)
		withMouseInfo { info in
			info.cursorWidth = Int(width)
			info.cursorHeight = Int(height)
			if prevHidden && !event.cursor.hidden {
				info.mouseX = Int32(event.cursor.positionX)
				info.mouseY = Int32(event.cursor.positionY)
			}
			info.cursorHotX = Int(event.cursor.hotX)
			info.cursorHotY = Int(event.cursor.hotY)
			if let cgimage = cgimage {
				info.cursorImg = cgimage
			}
		}
	}
	
	// Single owner of the audio session. .playback makes the stream ignore the
	// mute switch and, with UIBackgroundModes=audio and the always-running
	// queue, keeps the session alive while backgrounded.
	private func activateAudio() {
		let audio = _audioPtr
		audioSessionQueue.async {
			let session = AVAudioSession.sharedInstance()
			do {
				try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
				try session.setActive(true)
			} catch {
				Diagnostics.note("audio-session error=\((error as NSError).code)")
			}
			audio_start(audio)
		}
	}

	var isAudioKeepAliveActive: Bool {
		audioWanted && audio_is_running(_audioPtr)
	}

	func setMuted(_ muted: Bool) {
		audio_mute(muted, _audioPtr)
	}
	
	func applyConfig() {

		var parsecClientCfg = ParsecClientConfig()

		// Preserve the user's chosen resolution. The previous code hardcoded
		// 0/0 (= "use host default"), which silently overwrote whatever
		// connect() had set, making it look like the in-overlay Resolution
		// picker did nothing.
		let compatibility = ParsecVideoSuspendPolicy.decoderCompatibility(
			user: SettingsHandler.decoderCompatibility,
			flipped: decoderFlipped
		)
		parsecClientCfg.video.0.decoderIndex = 1
		parsecClientCfg.video.0.resolutionX = Int32(SettingsHandler.resolution.width)
		parsecClientCfg.video.0.resolutionY = Int32(SettingsHandler.resolution.height)
		parsecClientCfg.video.0.decoderCompatibility = compatibility
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = Int32(SettingsHandler.resolution.width)
		parsecClientCfg.video.1.resolutionY = Int32(SettingsHandler.resolution.height)
		parsecClientCfg.video.1.decoderCompatibility = compatibility
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = mediaContainer
		parsecClientCfg.protocol = netProtocol
		//parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = pngCursor

		ParsecClientSetConfig(_parsec, &parsecClientCfg);
	}

	/// `stopStream: false` (resign-active: Control Center, notification shade,
	/// app-switcher peek, system alerts): only pause the host. VideoToolbox
	/// stays valid, the renderer keeps the last frame, and unpausing makes the
	/// host send a keyframe — nothing to recover.
	/// `stopStream: true` (really backgrounded): also disable the stream so
	/// nothing reaches a decoder iPadOS invalidates. EnableStream(false) also
	/// destroys the SDK's GL renderer (same body as ParsecClientGLDestroy,
	/// 0x7a884), so this is reserved for the background.
	func setVideoSuspended(_ suspended: Bool, stopStream: Bool) {
		let event = suspended ? (stopStream ? "stop" : "suspend") : "resume"
		guard backgroundTaskRunning else {
			Diagnostics.note("video-pause event=\(event) result=skipped connected=false")
			return
		}
		if suspended {
			if !videoSuspended {
				videoSuspended = true
				videoResume = nil
				let pause = RemoteStatus(ParsecClientPause(_parsec, true, false))
				Diagnostics.note("video-pause event=suspend result=\(pause.rawValue)")
			}
			if stopStream && !streamStopped {
				// Device log 12:51:26: Pause alone did not stop the macOS host;
				// a frame decoded in the background → vt_callback -14 → dead
				// decode thread. A disabled stream delivers nothing.
				streamStopped = true
				let disable = RemoteStatus(ParsecClientEnableStream(_parsec, UInt8(DEFAULT_STREAM), false))
				Diagnostics.note("video-pause event=stop stream=\(disable.rawValue)")
			}
			return
		}
		guard videoSuspended else { return }
		videoSuspended = false
		if streamStopped {
			streamStopped = false
			// Force a fresh decoder before any resumed frame: the VT session
			// from before the background may be invalid. The config change
			// makes decode_thread drop it and wait for a keyframe, which the
			// re-enabled stream starts with.
			decoderFlipped.toggle()
			applyConfig()
			let enable = RemoteStatus(ParsecClientEnableStream(_parsec, UInt8(DEFAULT_STREAM), true))
			Diagnostics.note("video-stream event=enable result=\(enable.rawValue)")
			var status = ParsecClientStatus()
			ParsecClientGetStatus(_parsec, &status)
			videoResume = (CFAbsoluteTimeGetCurrent(), status.`self`.metrics.0.decodeLatency, false)
			Diagnostics.note("decoder-recovery event=awaiting-keyframe")
		}
		let result = RemoteStatus(ParsecClientPause(_parsec, false, false))
		Diagnostics.note("video-pause event=resume result=\(result.rawValue)")
	}

	/// Resume follow-up, driven by the session poll. Returns the status the
	/// transport monitor should see: a stalled resume is reported as -14 so the
	/// existing decode-error reconnect stays the last resort.
	private func checkVideoResume(_ status: RemoteStatus, decodeLatency: Float, rttMs: Float) -> RemoteStatus {
		guard let resume = videoResume else { return status }
		let elapsed = CFAbsoluteTimeGetCurrent() - resume.at
		let ms = Int(elapsed * 1000)
		switch ParsecVideoSuspendPolicy.recovery(
			elapsed: elapsed,
			decoded: decodeLatency != resume.decodeLatency,
			status: status,
			nudged: resume.nudged,
			rttMs: rttMs
		) {
		case .waiting:
			return status
		case .recovered:
			videoResume = nil
			Diagnostics.note("decoder-recovery event=first-frame ms=\(ms) decodeMs=\(String(format: "%.1f", decodeLatency))")
			return status
		case .failed:
			videoResume = nil
			Diagnostics.note("decoder-recovery event=failed ms=\(ms) status=\(status.rawValue)")
			return status
		case .nudge:
			videoResume?.nudged = true
			Diagnostics.note("decoder-recovery event=nudge ms=\(ms) rttMs=\(Int(rttMs)) action=decoder-reset")
			// Decoder reset → keyframe request (0x7f230). Cheaper than a host
			// video-config push, which restarts the encoder and throws away a
			// keyframe that may still be in flight on a slow link.
			DispatchQueue.main.async {
				self.decoderFlipped.toggle()
				self.applyConfig()
			}
			return status
		case .stalled:
			videoResume = nil
			Diagnostics.note("decoder-recovery event=stalled ms=\(ms) action=reconnect")
			// Only stand in for a missing frame; a real error keeps its code
			// (and its proper alert / transport handling).
			return status == .ok ? RemoteStatus(rawValue: -14) : status
		}
	}
	
	// All outgoing-input methods gate on backgroundTaskRunning. False means
	// we're between an explicit disconnect and the next connect (including
	// the gap inside changeResolution's reconnect dance) — sending into a
	// disconnected SDK is at best a wasted message and at worst a NULL deref
	// inside ParsecClientSendMessage.

	func sendMouseMessage(_ button:RemoteMouseButton, _ x:Int32, _ y:Int32, _ pressed: Bool)
	{
		guard backgroundTaskRunning else { return }
		// Send the mouse position
		sendMousePosition(x, y)

		// Send the mouse button state
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = ParsecMouseButton(rawValue: button.rawValue)
		buttonMessage.mouseButton.pressed = pressed
		sendGated(&buttonMessage)
	}

	func sendMouseClickMessage(_ button:RemoteMouseButton, _ pressed: Bool) {
		guard backgroundTaskRunning else { return }
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = ParsecMouseButton(rawValue: button.rawValue)
		buttonMessage.mouseButton.pressed = pressed
		sendGated(&buttonMessage)
	}

	func sendMouseDelta(_ dx: Int32, _ dy: Int32) {
		guard backgroundTaskRunning else { return }
		// One atomic snapshot, then act on it — avoids two separate locked
		// reads racing a concurrent position write.
		let info = mouseInfo
		if info.mousePositionRelative {
			sendMouseRelativeMove(dx, dy)
		} else {
			sendMousePosition(info.mouseX &+ dx, info.mouseY &+ dy)  // clamped inside
		}

	}

	// Apply only the explicit Windows editing mode. Direct HID remains raw;
	// Command-as-Control is one-way so physical Control never becomes Win.
	// Explicit Windows macros pass `.raw` and bypass configured remapping.
	static func remapKeyForHostIfNeeded(
		_ code: ParsecKeycode,
		intent: ParsecKeyboardMappingIntent = .configured
	) -> ParsecKeycode {
		let mapped = ParsecWindowsKeyboardMapping.map(
			RemoteKeyCode(rawValue: code.rawValue),
			mode: SettingsHandler.effectiveWindowsKeyboardMode,
			intent: intent
		)
		return ParsecKeycode(mapped.rawValue)
	}
	
	func sendMousePosition(_ x:Int32, _ y:Int32)
	{
		guard backgroundTaskRunning else { return }
		let cx = min(max(x, 0), Int32(self.clientWidth))
		let cy = min(max(y, 0), Int32(self.clientHeight))
		withMouseInfo {
			$0.mouseX = cx
			$0.mouseY = cy
		}
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = cx
		motionMessage.mouseMotion.y = cy
		sendGated(&motionMessage)
	}

	func sendMouseRelativeMove(_ dx:Int32, _ dy:Int32)
	{
		guard backgroundTaskRunning else { return }
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = dx
		motionMessage.mouseMotion.y = dy
		motionMessage.mouseMotion.relative = true
		sendGated(&motionMessage)
	}
	
	func getKeyCodeByText(text: String) -> (ParsecKeycode?, Bool) {
		var keyCode : ParsecKeycode?
		var useShift = false
		if text.count == 1 {
			let char = Character(text)
			if char.isLetter || char.isNumber {
				keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text.uppercased()).map { ParsecKeycode($0.rawValue) }
				if char.isUppercase {
					useShift = true
				}
			} else if char.isNewline {
				keyCode = ParsecKeycode(40)
			} else if char.isWhitespace{
				keyCode = ParsecKeycode(44)
			} else {
				let (keycodeRaw, keyMod) = KeyCodeTranslators.getRemoteKeyCode(for: text)
				if keycodeRaw != -1 {
					keyCode = ParsecKeycode(UInt32(keycodeRaw))
					if keyMod {
						useShift = true
					}
				}
			}
		} else {
			keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text).map { ParsecKeycode($0.rawValue) }
		}
		
		return (keyCode, useShift)
	}
	
	func sendVirtualKeyboardInput(text: String) {
		guard backgroundTaskRunning else { return }
		let (keyCode, useShift) = getKeyCodeByText(text: text)

		guard let keyCode else {
			return
		}
		let remapped = ParsecSDKBridge.remapKeyForHostIfNeeded(keyCode)
		// Shift injection is decided once at press time so the delayed
		// release always mirrors exactly what was pressed.
		let taps = ParsecVirtualKeyTap.sequence(
			code: remapped.rawValue,
			needsShift: useShift,
			shiftHeld: isVirtualShiftOn
		)
		let send = { (tap: (code: UInt32, pressed: Bool)) in
			var message = ParsecMessage()
			message.type = MESSAGE_KEYBOARD
			message.keyboard = ParsecKeyboardMessage(code: ParsecKeycode(tap.code), mod: MOD_NONE, pressed: tap.pressed, __pad: (0,0,0))
			self.sendGated(&message)
		}
		// One serial queue for every soft-keyboard tap: press, hold 20 ms (some
		// games ignore instant releases), release. Taps never overlap, so an
		// injected Shift can't leak into the next character of a paste
		// ("Hello" arriving as "HELLO") and order is preserved.
		// Bound to this session: a long paste still queued after a reconnect
		// must not keep typing into the new session.
		pollCondition.lock()
		let generation = pollGeneration
		pollCondition.unlock()
		virtualKeyQueue.async {
			guard self.shouldPoll(generation: generation) else { return }
			taps.filter { $0.pressed }.forEach(send)
			usleep(20_000)
			guard self.shouldPoll(generation: generation) else { return }
			taps.filter { !$0.pressed }.forEach(send)
		}
	}

	func sendKeyboardMessage(event:KeyBoardKeyEvent)
	{
		guard backgroundTaskRunning else { return }
		// Physical or toolbar Shift held: soft-keyboard taps must not inject
		// (and then release) their own Shift.
		if event.key.rawValue == 225 || event.key.rawValue == 229 {
			isVirtualShiftOn = event.isPressBegin
		}
		keyboardMappingLock.lock()
		let mappedCode = keyboardMappingLatch.map(
			event.key,
			pressed: event.isPressBegin,
			mode: SettingsHandler.effectiveWindowsKeyboardMode,
			intent: event.mappingIntent
		)
		keyboardMappingLock.unlock()

		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.code = ParsecKeycode(mappedCode.rawValue)
		keyboardMessagePress.keyboard.pressed = event.isPressBegin
		let sent = sendGated(&keyboardMessagePress)
		// A lost key-up is a stuck key on the host; make it visible in logs.
		if sent != PARSEC_OK && !event.isPressBegin {
			Diagnostics.note("input-release-failed status=\(sent.rawValue)")
		}
	}
	
	func sendGameControllerButtonMessage(controllerId: UInt32, _ button:RemoteGamepadButton, pressed: Bool)
	{
		guard backgroundTaskRunning else { return }
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_BUTTON
		pmsg.gamepadButton.id = controllerId
		pmsg.gamepadButton.button = ParsecGamepadButton(rawValue: button.rawValue)
		pmsg.gamepadButton.pressed = pressed
		sendGated(&pmsg)
	}
	
	/*static func sendGameControllerTriggerButtonMessage(controllerId: UInt32, _ button:ParsecGamepadAxis, pressed: Bool)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.button = button
		pmsg.gamepadAxis.pressed = pressed
		sendGated(&pmsg)
	}*/
	
	func sendGameControllerAxisMessage(controllerId: UInt32, _ axis:RemoteGamepadAxis, _ value: Int16)
	{
		guard backgroundTaskRunning else { return }
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.axis = ParsecGamepadAxis(rawValue: axis.rawValue)
		pmsg.gamepadAxis.value = value
		sendGated(&pmsg)
	}
	
	func sendGameControllerUnplugMessage(controllerId: UInt32)
	{
		guard backgroundTaskRunning else { return }
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_UNPLUG;
		pmsg.gamepadUnplug.id = controllerId;
		sendGated(&pmsg)
	}
	
	func sendWheelMsg(x: Int32, y: Int32) {
		guard backgroundTaskRunning else { return }
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_MOUSE_WHEEL;
		pmsg.mouseWheel.x = x
		pmsg.mouseWheel.y = y
		sendGated(&pmsg)
	}
	
	func startBackgroundTask(){
		// Scale poll timeout to the configured render fps so the audio and
		// event threads don't sit blocked inside the SDK longer than a
		// frame budget. On 120 Hz iPads that's 8 ms; on 60 Hz, 16 ms.
		let fps = SettingsHandler.preferredFramesPerSecond == 0
			? UIScreen.main.maximumFramesPerSecond
			: SettingsHandler.preferredFramesPerSecond
		let pollTimeout = UInt32(max(1000 / fps, 8))

		pollCondition.lock()
		guard activePollerCount == 0 else {
			let active = activePollerCount
			pollCondition.unlock()
			Diagnostics.note("sdk-poll event=start-rejected active=\(active)")
			return
		}
		pollGeneration &+= 1
		let generation = pollGeneration
		isPolling = true
		activePollerCount = 2
		pollCondition.unlock()
		Diagnostics.note("sdk-poll event=started generation=\(generation) active=2")

		let audioItem = DispatchWorkItem {
			defer { self.pollerDidFinish() }
			while self.shouldPoll(generation: generation) {
				self.pollAudio(timeout: pollTimeout)
			}
		}
		let eventItem = DispatchWorkItem {
			defer { self.pollerDidFinish() }
			while self.shouldPoll(generation: generation) {
				self.pollEvent(timeout: pollTimeout)
			}
		}
		let pollQueue = DispatchQueue.global(qos: .userInteractive)
		pollQueue.async(execute: audioItem)
		pollQueue.async(execute: eventItem)
	}

	private func shouldPoll(generation: UInt64) -> Bool {
		pollCondition.lock()
		defer { pollCondition.unlock() }
		return isPolling && pollGeneration == generation
	}

	private func pollerDidFinish() {
		pollCondition.lock()
		activePollerCount -= 1
		pollCondition.broadcast()
		pollCondition.unlock()
	}

	private func stopBackgroundTaskAndWait() {
		pollCondition.lock()
		isPolling = false
		pollGeneration &+= 1
		while activePollerCount > 0 {
			pollCondition.wait()
		}
		let generation = pollGeneration
		pollCondition.unlock()
		Diagnostics.note("sdk-poll event=drained generation=\(generation) active=0")
	}
	
	func sendUserData(type: ParsecUserDataType, message: Data) {
		// V2: the only send* method that was missing this gate — protects
		// against a NULL deref inside ParsecClientSendUserData during the
		// disconnect→reconnect gap, consistent with every other send path.
		guard backgroundTaskRunning else { return }
        var nullTerminatedMessage = message
        nullTerminatedMessage.append(0)
		nullTerminatedMessage.withUnsafeBytes { ptr in
			let ptr2 = ptr.baseAddress?.assumingMemoryBound(to: CChar.self)
			sendGate.lock()
			defer { sendGate.unlock() }
			guard backgroundTaskRunning else { return }
			ParsecClientSendUserData(_parsec, type.rawValue, ptr2)
		}
	}
	
	func updateHostVideoConfig() {
		var videoConfig = ParsecUserDataVideoConfig()
		videoConfig.video[0].resolutionX = DataManager.model.resolutionX
		videoConfig.video[0].resolutionY = DataManager.model.resolutionY
		// Clamp at the one point bitrate reaches the host encoder: above
		// maxSafeHostBitrate the host's large H.265 keyframes overflow the SDK's
		// BUD reassembler and crash decode_thread (see ParsecVideoSuspendPolicy).
		let safeBitrate = ParsecVideoSuspendPolicy.safeHostBitrate(DataManager.model.bitrate)
		videoConfig.video[0].encoderMaxBitrate = safeBitrate
		videoConfig.video[0].fullFPS = DataManager.model.constantFps
		videoConfig.video[0].output = DataManager.model.output
		let encoder = JSONEncoder()
		let data = try! encoder.encode(videoConfig)

		// S06: bump the revision so any in-flight resend from a previous call
		// drops, and record the user-owned fields so the case-11 echo confirms
		// (rather than reverts) this selection.
		configRevision &+= 1
		let revision = configRevision
		// Record the clamped value so the host's echo (which reports the capped
		// bitrate) confirms this push instead of being treated as a mismatch.
		pendingUserConfig = (safeBitrate, DataManager.model.constantFps)
		// Track a concrete display switch so the confirm-and-retry loop below can
		// keep re-asserting it. "none" (Auto) has no stable echoed id to confirm
		// against, so it just rides the base send + the existing 250 ms resend.
		let switchTarget = DataManager.model.output
		Diagnostics.note(
			"video-config event=push revision=\(revision) output=\(switchTarget) " +
			"bitrate=\(videoConfig.video[0].encoderMaxBitrate) fullFPS=\(videoConfig.video[0].fullFPS) " +
			"res=\(videoConfig.video[0].resolutionX)x\(videoConfig.video[0].resolutionY)"
		)
		if switchTarget != "none" && !switchTarget.isEmpty && switchTarget != hostOutput {
			pendingOutputSince = Date()
			pendingOutput = switchTarget
			scheduleDisplaySwitchRetry(revision: revision, data: data, attempt: 0)
		} else {
			pendingOutput = nil
		}

		CParsec.sendUserData(type: .setVideoConfig, message: data)
		// User reports: display switches needed two or three taps to actually
		// take effect. setVideoConfig is fire-and-forget; the host can drop
		// the message if its encoder is in the middle of a reset triggered
		// by a previous request. Re-send the same payload after 250 ms
		// (idempotent — same output reapplied is a no-op on the host), but only
		// if this call is still the latest (a newer tap supersedes it).
		// Then ask the host to echo back its current config so case-11
		// confirms the switch landed.
		// Every push restarts the host encoder (stutter + keyframe), so resend
		// only if the host's echo has not confirmed it after 1 s. Display
		// switches have their own confirm/retry loop below.
		let empty = Data()
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.45) { [weak self] in
			guard let self = self, self.backgroundTaskRunning, self.configRevision == revision else { return }
			CParsec.sendUserData(type: .getVideoConfig, message: empty)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			guard let self = self, self.backgroundTaskRunning, self.configRevision == revision,
				  self.pendingUserConfig != nil else { return }
			Diagnostics.note("video-config event=resend revision=\(revision) reason=unconfirmed")
			CParsec.sendUserData(type: .setVideoConfig, message: data)
			CParsec.sendUserData(type: .getVideoConfig, message: empty)
		}
		// Self-heal: drop the pending guard after a confirmation window so a
		// host that never echoes our exact value can't permanently block future
		// echo adoption of bitrate/fps. Only clears if still the latest call.
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
			guard let self = self, self.configRevision == revision else { return }
			self.pendingUserConfig = nil
		}
	}

	// Re-assert a display switch on a widening schedule until the host's case-11
	// echo confirms it (which clears pendingOutput) or we exhaust the attempts.
	// A display change re-inits the host encoder for the new output; a request
	// that lands during that reset is dropped, so one fire-and-forget send (or a
	// single 250 ms resend, which fires while the host is often still busy) was
	// unreliable — hence the historical "needs two or three taps". Each resend is
	// idempotent (same output reapplied is a no-op once it's the active display),
	// so over-asserting is harmless; under-asserting was the bug.
	private func scheduleDisplaySwitchRetry(revision: Int, data: Data, attempt: Int) {
		let delays: [Double] = [0.35, 0.8, 1.5, 2.5]
		guard attempt < delays.count else {
			// Give up re-asserting; drop the guard so a host that never echoes a
			// matching output can't leave it pending forever.
			DispatchQueue.main.async { [weak self] in
				guard let self = self, self.configRevision == revision, let out = self.pendingOutput else { return }
				self.pendingOutput = nil
				Diagnostics.note("display-output event=timeout output=\(out) ms=\(Int(Date().timeIntervalSince(self.pendingOutputSince) * 1000))")
			}
			return
		}
		DispatchQueue.global().asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
			guard let self = self, self.backgroundTaskRunning, self.configRevision == revision else { return }
			// pendingOutput is mutated on the main queue (set in updateHostVideoConfig,
			// cleared by the case-11 confirmation echo). It's a String?, not an atomic
			// scalar, so read it on main to avoid racing that clear. Re-assert there if
			// the switch is still unconfirmed — sending on main is fine (the base send
			// at the top of updateHostVideoConfig already does).
			DispatchQueue.main.async {
				guard self.backgroundTaskRunning, self.configRevision == revision, let out = self.pendingOutput else { return }
				Diagnostics.note("display-output event=retry attempt=\(attempt + 1) output=\(out)")
				CParsec.sendUserData(type: .setVideoConfig, message: data)
				let empty = "".data(using: .utf8)!
				CParsec.sendUserData(type: .getVideoConfig, message: empty)
				self.scheduleDisplaySwitchRetry(revision: revision, data: data, attempt: attempt + 1)
			}
		}
	}
}
#endif
