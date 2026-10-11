import SwiftUI
import Foundation
import AVFoundation

struct ParsecStatusBar : View {
	@Binding var isReconfiguring : Bool
	@Binding var showMenu : Bool
	@State var metricInfo: String = "Loading..."
	@Binding var showDCAlert: Bool
	@Binding var DCAlertText: String
	@State var parsecViewController: ParsecViewController?
	@State var wasDisconnected: Bool = true
	@State private var decodeErrorTolerated = false
	// Pure policy owns the failure streak and one-reconnect budget; the
	// background manager remains the only scheduler/effect owner.
	@State private var transportRecovery = ParsecTransportRecoveryMonitor(
		failureThreshold: 5
	)
	let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

	// Translate a raw SDK status into something a user can act on; the raw
	// code is always appended so anything new can still be triaged. Meanings
	// follow parsec.h and Parsec's published error-code articles.
	static func failureMessage(forCode code: Int, connecting: Bool = false) -> String {
		let prefix = connecting ? "Couldn't connect" : "Disconnected"
		let reason: String
		switch code {
		case -6013:
			reason = "UDP traffic is blocked. A VPN that doesn't pass UDP is the usual cause: use split tunneling (VPN only for *.parsec.app) or turn the VPN off once connected."
		case -6023, -6024, -6025, -6033:
			reason = "a peer-to-peer connection couldn't be negotiated (network/NAT). Check Wi-Fi, the host's firewall, and UPnP / port forwarding."
		case -6101, -6105, -6106, -3002, -3003, -3009:
			reason = "Parsec's servers couldn't be reached. They are needed to start or restore a connection; where Parsec is blocked, turn on a VPN for *.parsec.app."
		case -3008:
			reason = "your Parsec session is no longer valid. Sign in again."
		case -12007, -12019:
			reason = "the network was interrupted."
		case 4:
			reason = "the host shut down or stopped hosting."
		case 5:
			reason = "the host disconnected you."
		case 8:
			reason = "the host declined the connection."
		case 9:
			reason = "the connection was canceled."
		case 11:
			reason = "the host has no free guest slots."
		case 99:
			reason = "the host is no longer available."
		case 112:
			reason = "you don't have permission to connect to this host."
		default:
			return "\(prefix) (code \(code))"
		}
		return "\(prefix): \(reason)\n(code \(code))"
	}

	static func disconnectMessage(forCode code: Int) -> String {
		failureMessage(forCode: code)
	}

	init(isReconfiguring: Binding<Bool>, showMenu: Binding<Bool>, showDCAlert: Binding<Bool>, DCAlertText: Binding<String>, parsecViewController: ParsecViewController) {
		_isReconfiguring = isReconfiguring
		_showMenu = showMenu
		_showDCAlert = showDCAlert
		_DCAlertText = DCAlertText
		self.parsecViewController = parsecViewController
	}
	
	var body: some View {
		// Overlay elements
		if showMenu
		{
			VStack()
			{
				Text(metricInfo)
					.frame(minWidth:200, maxWidth:.infinity, maxHeight:20)
					.multilineTextAlignment(.leading)
					.font(.system(size: 10))
					.lineSpacing(20)
					.lineLimit(nil)
			}
			.background(Rectangle().fill(Color("BackgroundPrompt").opacity(0.75)))
			.foregroundColor(Color("Foreground"))
			.frame(maxHeight: .infinity, alignment: .top)
			.zIndex(1)
			.edgesIgnoringSafeArea(.all)

		}
		EmptyView()
			.onReceive(timer) { p in
				poll()
			}

		// Reconnecting overlay — only visible during changeResolution's
		// disconnect→reconnect dance. Mirrors MainView's connecting overlay.
		if isReconfiguring {
			ZStack {
				Rectangle()
					.fill(Color.black.opacity(0.45))
					.edgesIgnoringSafeArea(.all)
				VStack(spacing: 12) {
					ProgressView()
						.scaleEffect(1.4)
						.progressViewStyle(CircularProgressViewStyle(tint: .white))
					Text("Switching resolution…")
						.foregroundColor(.white)
						.font(.system(size: 16, weight: .medium))
				}
				.padding(24)
				.background(
					RoundedRectangle(cornerRadius: 12)
						.fill(Color("BackgroundPrompt").opacity(0.85))
				)
			}
			.zIndex(3)
		}
	}

	func poll()
	{
		// While we're deliberately disconnecting/reconnecting for a resolution
		// change, getStatusEx will briefly report a non-OK status. Don't pop
		// the "Disconnected" alert during that window — it's an intentional
		// gap with an overlay in front of it.
		if isReconfiguring
		{
			return
		}
		if showDCAlert
		{
			return // no need to poll if we aren't connected anymore
		}

		// The background manager exclusively owns grace expiry and foreground
		// recovery. Real ParsecSDK status can be transiently unavailable while
		// iPadOS backgrounds render/network work; counting those polls as transport
		// failures tears down the session before the grace window can do its job.
		guard ParsecTransportObservationPolicy.isAllowed(
			applicationState: UIApplication.shared.applicationState
		) else {
			return
		}
		// Between connect retries the SDK is intentionally disconnected (-3);
		// the runner owns the outcome and reports it itself.
		if ParsecConnectRunner.shared.isRunning { return }
		
		let generation = CParsec.sessionSnapshot.generation
		let clientStatus = CParsec.getStatusEx(generation: generation)
		guard CParsec.sessionSnapshot.generation == generation else { return }
		// Decoder errors (-10…-23) are sticky in GetStatus until the next connect,
		// but the SDK re-creates the hardware decoder itself: after even a 1 s
		// app switch iPadOS reclaims it, GetStatus says -14 forever, and frames
		// keep flowing. Treat that as healthy while new frames arrive; only a
		// real gap (no new frame for 3 s) counts as a transport failure.
		let status = ParsecDecodeErrorPolicy.effectiveStatus(
			clientStatus.status,
			secondsSinceNewFrame: CACurrentMediaTime() - RenderClock.lastNewFrameAt
		)
		if status != clientStatus.status, !decodeErrorTolerated {
			decodeErrorTolerated = true
			Diagnostics.note("decode-error-tolerated status=\(clientStatus.status.rawValue) generation=\(generation)")
		}
		RenderClock.check(
			paused: (parsecViewController?.glkView as? ParsecGLKViewController)?.glkViewController.isPaused ?? false,
			detail: "status=\(status.rawValue) queued=\(clientStatus.metrics.queuedFrames) decodeMs=\(String(format: "%.1f", clientStatus.metrics.decodeLatency)) encodeMs=\(String(format: "%.1f", clientStatus.metrics.encodeLatency)) netMs=\(String(format: "%.1f", clientStatus.metrics.networkLatency)) app=\(UIApplication.shared.applicationState.rawValue)"
		)
		
		if status != .ok
		{
			if ParsecBackgroundManager.shared.isMarkedForReconnect {
				return
			}

			// PiP: connection died (screen lock killed GPU). Kill connection+audio once,
			// subsequent polls exit via isMarkedForReconnect above.
			var pipActive = false
			if #available(iOS 15.0, *) {
				pipActive = PictureInPictureManager.shared.isPiPActive
			}
			if pipActive {
				let disconnected = CParsec.disconnect(
					reason: .transportFailure,
					generation: generation
				)
				if disconnected {
					ParsecBackgroundManager.shared.markForReconnect()
					wasDisconnected = true
				}
				return
			}

			let effect = transportRecovery.observe(
				status: status,
				generation: generation,
				isReplacementGeneration: CParsec.sessionSnapshot.connectIntent == .reconnect,
				isSessionInteractive: CParsec.sessionSnapshot.phase == .interactive
			)
			CParsec.publishTransportRecovery(transportRecovery.snapshot)
			if let effect {
				Diagnostics.note("transport-\(effect) status=\(status.rawValue) generation=\(generation) \(NetworkPathObserver.digest)")
			}
			switch effect {
			case let .reconnect(recoveryGeneration):
				wasDisconnected = true
				let disconnected = CParsec.disconnect(
					reason: .transportFailure,
					generation: recoveryGeneration
				)
				if disconnected {
					ParsecBackgroundManager.shared.schedulePendingReconnect()
				}
			case let .terminal(_, terminalStatus):
				wasDisconnected = true
				DCAlertText = Self.disconnectMessage(
					forCode: Int(terminalStatus.rawValue)
				)
				showDCAlert = true
			case nil:
				break
			}
			return
		}

		// Status is OK — clear any in-flight failure streak and retire a
		// replacement generation's reconnect budget once it is interactive.
		_ = transportRecovery.observe(
			status: status,
			generation: generation,
			isReplacementGeneration: CParsec.sessionSnapshot.connectIntent == .reconnect,
			isSessionInteractive: CParsec.sessionSnapshot.phase == .interactive
		)
		CParsec.publishTransportRecovery(transportRecovery.snapshot)
		ParsecBackgroundManager.shared.foregroundTransportRemainedUsable(
			generation: generation
		)

		if showMenu
		{
			let metrics = clientStatus.metrics
			let decoder = clientStatus.decoder
			let snapshot = CParsec.sessionSnapshot
			metricInfo = "\(snapshot.digest)\nDecode \(String(format:"%.2f", metrics.decodeLatency))ms    Encode \(String(format:"%.2f", metrics.encodeLatency))ms    Network \(String(format:"%.2f", metrics.networkLatency))ms    Bitrate \(String(format:"%.2f", metrics.bitrate))Mbps    Queue \(metrics.queuedFrames)    RT \(metrics.fastRetransmits)/\(metrics.slowRetransmits)    \(decoder.usesH265 ? "H265" : "H264") \(decoder.width)x\(decoder.height) \(decoder.usesColor444 ? "4:4:4" : "4:2:0") \(decoder.name)"
		}
	}
}

// CRITICAL: This class exists to PERSIST the ParsecViewController instance across SwiftUI view updates.
// Do not remove or change to a struct. If ParsecViewController is recreated, the keyboard responder chain breaks.
class ParsecSession: ObservableObject {
    let controller: ParsecViewController
    
    init() {
        self.controller = ParsecViewController()
    }
}

struct ParsecView: View
{
	var controller:ContentView?
	
	@State var showDCAlert: Bool = false
	@State var DCAlertText: String = "Disconnected (reason unknown)"
	@State private var mediaRecoveryTerminal: Bool = false
	@State var metricInfo: String = "Loading..."
	
	@State var hideOverlay: Bool = false
	@State var showMenu: Bool = false
	@State private var showSettings: Bool = false

	@State var showKeyboard: Bool = false
	@State var zoomEnabled: Bool = false
	// True while changeResolution is in its disconnect→reconnect dance.
	// Suppresses the status-bar disconnect alert and shows a small
	// "Switching resolution…" overlay so the user knows what's happening.
	@State var isReconfiguring: Bool = false
	@State private var hostConfigRequestGate = ParsecGenerationRequestGate()

	@State var muted: Bool = false
	@State var preferH265: Bool = true
	@State var constantFps = false
	
	@State var resolutions: [ParsecResolution]
	@State var bitrates: [Int]
	
    // Persist the VC across view updates using StateObject.
    // CRITICAL: Changing this to @State or a simple var will break the keyboard after menu interactions.
	@StateObject var session = ParsecSession()
    
    // Observer shared state for updates
    @ObservedObject var dataModel = DataManager.model
    
    // Computed property for convenience refactoring
    var parsecViewController: ParsecViewController {
        return session.controller
    }


	//@State var showDisplays: Bool = false
	
	init(_ controller: ContentView?)
	{
		self.controller = controller

		let save = SettingsHandler.saveSessionSettings
		_muted = State(initialValue: save ? SettingsHandler.savedMuted : false)
		_zoomEnabled = State(initialValue: save ? SettingsHandler.savedZoomEnabled : false)
		_constantFps = State(initialValue: save ? SettingsHandler.savedConstantFps : false)
		_resolutions = State(initialValue: ParsecResolution.resolutions)
		_bitrates = State(initialValue: ParsecResolution.bitrates)

    }
	    
    // We need to set up the callback somewhere safer than init.
    // 'onAppear' is a good place, or inside the init of ParsecSession if possible (but it doesn't have access to binding).
    // Let's use onAppear/post.

	var body: some View
	{
		ZStack()
		{
			
			UIViewControllerWrapper(self.parsecViewController)
				.zIndex(1)
				.prefersPersistentSystemOverlaysHidden()
			
			ParsecStatusBar(isReconfiguring: $isReconfiguring, showMenu: $showMenu, showDCAlert: $showDCAlert, DCAlertText: $DCAlertText, parsecViewController: parsecViewController)

			if OpenParsecRuntime.isUITesting {
				SessionDiagnosticsAccessibilityView(exposesPhase: true)
			}
			
			VStack()
			{
				if !hideOverlay
				{
					HStack()
					{
						Button(action:{
							if showMenu {
								showMenu = false
							} else {
								showMenu = true
								getHostUserData()
							}
						})
						{
							Image("IconTransparent")
								.resizable()
								.aspectRatio(contentMode: .fit)
								.frame(width:34, height:34)
								.padding(3)
								.background(Rectangle().fill(Color("BackgroundPrompt").opacity(showMenu ? 0.75 : 1)))
								.cornerRadius(10)
								.opacity(showMenu ? 1 : 0.22)
						}
						.padding(10)
						.edgesIgnoringSafeArea(.all)
						.accessibilityIdentifier("openparsec.session")
						Spacer()
					}
					if SettingsHandler.showKeyboardButton {
						HStack()
						{
							Button(action: toggleKeyboard)
							{
								Image(systemName: "keyboard")
									.resizable()
									.aspectRatio(contentMode: .fit)
									.frame(width:24, height:24)
									.foregroundColor(Color("Foreground"))
									.padding(7)
									.background(Rectangle().fill(Color("BackgroundPrompt").opacity(showKeyboard ? 0.75 : 0.5)))
									.cornerRadius(8)
							}
							.padding(.leading, 10)
							.edgesIgnoringSafeArea(.all)
							Spacer()
						}
					}

				}
				if showMenu
				{	
					HStack()
					{
						VStack(spacing:1)
						{
							Button(action: { showSettings = true; showMenu = false })
							{
								Text("Settings")
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
							Button(action:disableOverlay)
							{
								Text("Hide Overlay")
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
							Button(action: toggleMute)
							{
								Text("Sound: \(muted ? "OFF" : "ON")")
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
							Menu() {
								ForEach(resolutions, id: \.self) { resolution in
									let isCurrent = resolution.width == dataModel.resolutionX && resolution.height == dataModel.resolutionY
									Button(action: {
										changeResolution(res: resolution)
									}) {
										// iOS 14.0–14.4's UIMenu bridge crashes when SwiftUI lowers a
										// `if Label else Text` body inside a Menu's Button to
										// `_ConditionalContent<Label, Text>`. A single homogeneous
										// HStack with a conditional Image is safe and renders the
										// same checkmark visual.
										HStack {
											Text(resolution.desc)
											if isCurrent {
												Spacer(minLength: 8)
												Image(systemName: "checkmark")
											}
										}
									}
								}
							} label: {
								Text("Resolution")
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
							Menu() {
								ForEach(bitrates, id: \.self) { bitrate in
									let isCurrent = bitrate == dataModel.bitrate
									Button(action: {
										changeBitRate(bitrate: bitrate)
									}) {
										HStack {
											Text("\(bitrate) Mbps")
											if isCurrent {
												Spacer(minLength: 8)
												Image(systemName: "checkmark")
											}
										}
									}
								}
							} label: {
								Text("Bitrate")
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
							if let target = ParsecDisplayConfig.toggleTarget(in: dataModel.displayConfigs, current: dataModel.output) {
								// Two monitors: one tap flips to the other one.
								Button(action: { changeDisplay(displayId: target.id) }) {
									Text("Switch to \(target.menuLabel(in: dataModel.displayConfigs))")
										.padding(.vertical, 7)
										.padding(.horizontal, 8)
										.frame(maxWidth:.infinity)
										.multilineTextAlignment(.center)
								}
							} else if (dataModel.displayConfigs.count > 2) {
								Menu() {
									Button(action: { changeDisplay(displayId: "none") }) {
										HStack {
											Text("Auto")
											if dataModel.output == "none" {
												Spacer(minLength: 8)
												Image(systemName: "checkmark")
											}
										}
									}
									ForEach(dataModel.displayConfigs, id: \.self) { config in
										Button(action: { changeDisplay(displayId: config.id) }) {
											HStack {
												Text(config.menuLabel(in: dataModel.displayConfigs))
												if config.id == dataModel.output {
													Spacer(minLength: 8)
													Image(systemName: "checkmark")
												}
											}
										}
									}
								} label: {
									Text("Switch Display")
										.padding(8)
										.frame(maxWidth:.infinity)
										.multilineTextAlignment(.center)
								}
							}

							Button(action: toggleConstantFps)
							{
								Text("Constant FPS: \(dataModel.constantFps ? "ON" : "OFF")")
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
							if CParsec.hostOS != .windows {
								// macOS "Turn Dock hiding on/off" is ⌥⌘D.
								Button(action: {
									let chord = ["LGUI", "LALT", "D"].compactMap(KeyCodeTranslators.parsecKeyCodeTranslator)
									CParsec.sendKeyboardChord(chord, route: .explicitMacro, mappingIntent: .raw)
								})
								{
									Text("Hide / Show Dock")
										.padding(.vertical, 7)
										.padding(.horizontal, 8)
										.frame(maxWidth:.infinity)
										.multilineTextAlignment(.center)
								}
							}
							Button(action: toggleZoom)
							{
								Text("Zoom: \(zoomEnabled ? "ON" : "OFF")")
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
							Rectangle()
								.fill(Color("Foreground"))
								.opacity(0.25)
								.frame(height:1)
							Button(action: { disconnect()})
							{
								Text("Disconnect")
									.foregroundColor(.red)
									.padding(.vertical, 7)
									.padding(.horizontal, 8)
									.frame(maxWidth:.infinity)
									.multilineTextAlignment(.center)
							}
						}
						.font(.subheadline)
						.background(Rectangle().fill(Color("BackgroundPrompt").opacity(0.8)))
						.foregroundColor(Color("Foreground"))
						.frame(maxWidth:160)
						.cornerRadius(10)
						.padding(.horizontal)
						//.edgesIgnoringSafeArea(.all)
						Spacer()
					}
				}
				Spacer()
			}
			.zIndex(2)

			// In-session settings: "live" settings apply immediately through
			// SettingsHandler.notifyChanged; connect-time ones on next connect.
			SettingsView(visible: $showSettings)
				.zIndex(3)
		}
		.statusBarHidden(SettingsHandler.hideStatusBar)
		.onChange(of: showMenu) { _ in
			// Trackpad clicks on the session menu must not also click the host.
			ParsecViewController.sessionOverlayActive = showMenu || showSettings
			parsecViewController.setNeedsUpdateOfPrefersPointerLocked()
			parsecViewController.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
		}
		.onChange(of: showSettings) { visible in
			ParsecViewController.sessionOverlayActive = showMenu || visible
			// "Hide Session Button" applies as soon as Settings closes.
			if !visible { hideOverlay = SettingsHandler.noOverlay }
			parsecViewController.setNeedsUpdateOfPrefersPointerLocked()
			parsecViewController.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
		}
		.alert(isPresented:$showDCAlert)
		{
			Alert(
				title: Text(DCAlertText),
				dismissButton: .default(
					Text("Close"),
					action: {
						let reason: ParsecDisconnectReason = mediaRecoveryTerminal
							? .user
							: .transportFailure
						mediaRecoveryTerminal = false
						disconnect(reason: reason)
					}
				)
			)
		}
		.onAppear(perform:post)
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ParsecBackgroundDisconnect"))) { _ in
			var pictureInPictureActive = false
			if #available(iOS 15.0, *) {
				pictureInPictureActive = PictureInPictureManager.shared.isPiPActive
			}
			let automaticReconnectPending = ParsecBackgroundManager.shared.isMarkedForReconnect
			let preservesBackgroundPresentation = ParsecBackgroundManager.shared.shouldPreserveSessionPresentation
			guard ParsecRecoveryPresentationPolicy.shouldDismissSession(
				pictureInPictureActive: pictureInPictureActive,
				automaticReconnectPending: automaticReconnectPending,
				preservesBackgroundPresentation: preservesBackgroundPresentation
			) else {
				if !pictureInPictureActive,
				   automaticReconnectPending,
				   preservesBackgroundPresentation {
					// Stop drawing against the disconnected SDK generation. The
					// validated replacement resumes this same GLK surface below.
					parsecViewController.glkView?.cleanUp()
				}
				return
			}
			disconnect(isBackgroundDisconnect: true)
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .parsecSessionSnapshotDidChange)
		) { notification in
			guard let snapshot = notification.object as? ParsecSessionSnapshot,
			      snapshot.connectIntent == .reconnect,
			      snapshot.transportStatus == .ok,
			      CParsec.sessionSnapshot.generation == snapshot.generation else { return }
			var requestGate = hostConfigRequestGate
			let shouldRequestHostConfig = requestGate.claim(
				generation: snapshot.generation
			)
			hostConfigRequestGate = requestGate
			DispatchQueue.main.async {
				parsecViewController.replaceRenderSurfaceForReconnect(
					generation: snapshot.generation
				)
				if shouldRequestHostConfig {
					getHostUserData()
					Diagnostics.note(
						"host-config event=request generation=\(snapshot.generation) reason=reconnect"
					)
				}
			}
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .parsecDisplayOutputDidConfirm)
		) { _ in
			// Confirms can land seconds after changeDisplay's fixed 1 s resume
			// (device log: 4 s on restore); repaint after the host's encoder reset too.
			parsecViewController.glkView?.resume()
			parsecViewController.synchronizeRenderDimensions()
		}
		.onReceive(
			NotificationCenter.default.publisher(for: .parsecMediaRecoveryActionRequested)
		) { notification in
			guard let action = notification.object as? ParsecMediaRecoveryAction else { return }
			handleMediaRecoveryAction(action)
		}
		.edgesIgnoringSafeArea(.all)

	}
	
	private func handleMediaRecoveryAction(_ action: ParsecMediaRecoveryAction) {
		Diagnostics.note("media-recovery action=\(action) \(CParsec.sessionSnapshot.digest)")
		switch action {
		case let .resumeVideoSurface(generation):
			guard CParsec.sessionSnapshot.generation == generation else { return }
			parsecViewController.glkView?.resume()
		case let .reconnect(generation):
			guard CParsec.sessionSnapshot.generation == generation else { return }
			disconnect(
				isBackgroundDisconnect: true,
				reason: .transportFailure
			)
			ParsecBackgroundManager.shared.sceneDidBecomeActive()
		case let .terminalFailure(generation, stage):
			guard CParsec.sessionSnapshot.generation == generation else { return }
			ParsecBackgroundManager.shared.disableAutoReconnect()
			mediaRecoveryTerminal = true
			let channel = stage == .audio ? "Audio" : "Video"
			let code = CParsec.sessionSnapshot.lastFailure?.rawCode ?? 0
			DCAlertText = "\(channel) did not recover after one automatic reconnect (code \(code))."
			showDCAlert = true
		}
	}

	func post()
	{
		let recoverySnapshot = CParsec.mediaRecoverySnapshot
		if recoverySnapshot.phase == .terminalFailure,
		   let stage = CParsec.sessionSnapshot.lastFailure?.stage {
			handleMediaRecoveryAction(
				.terminalFailure(
					generation: recoverySnapshot.generation,
					stage: stage
				)
			)
		}

		ParsecBackgroundManager.shared.onShouldDisconnect = {
			NotificationCenter.default.post(name: NSNotification.Name("ParsecBackgroundDisconnect"), object: nil)
		}
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.onPiPStarted = { protectedGeneration in
				ParsecBackgroundManager.shared.pictureInPictureDidStart(
					generation: protectedGeneration
				)
			}
			PictureInPictureManager.shared.onPiPStopped = { protectedGeneration in
				let isBackgrounded = UIApplication.shared.applicationState != .active
				if isBackgrounded {
					ParsecBackgroundManager.shared.pictureInPictureProtectionEnded(
						whileBackgrounded: true,
						generation: protectedGeneration
					)
					return
				}

				guard !ParsecBackgroundManager.shared.isReconnecting else { return }
				let currentStatus = CParsec.getStatusEx(
					generation: protectedGeneration
				).status
				guard CParsec.sessionSnapshot.generation == protectedGeneration else { return }
				if currentStatus != .ok || ParsecBackgroundManager.shared.isMarkedForReconnect {
					_ = ParsecBackgroundManager.shared.transportBecameUnusable(
						generation: protectedGeneration
					)
				}
			}
			PictureInPictureManager.shared.onPiPStartFailed = { protectedGeneration in
				ParsecBackgroundManager.shared.pictureInPictureProtectionEnded(
					whileBackgrounded: UIApplication.shared.applicationState != .active,
					generation: protectedGeneration
				)
			}
		}

		CParsec.applyConfig()
		CParsec.setMuted(muted)
		parsecViewController.setZoomEnabled(zoomEnabled)

		// Seed the session's Constant FPS (saved value, else OFF) — the first
		// case-11 echo keeps it and pushes it instead of adopting host default.
		DataManager.model.constantFps = constantFps

		let screenSize: CGSize = self.parsecViewController.view.frame.size
		let scaleFactor = UIScreen.main.nativeScale
		ParsecResolution.updateClientResolution(
			width: Int(screenSize.width * scaleFactor),
			height: Int(screenSize.height * scaleFactor)
		)

		getHostUserData()

		hideOverlay = SettingsHandler.noOverlay

        // Capture only the binding: capturing the view struct retained the
        // StateObject (and so the controller) from inside the controller.
        parsecViewController.onKeyboardVisibilityChanged = { [binding = $showKeyboard] visible in
            binding.wrappedValue = visible
        }

		parsecViewController.setKeyboardVisible(showKeyboard)
	}
	
	
	func disableOverlay()
	{
		hideOverlay = true
		showMenu = false
	}
	
	func toggleMute()
	{
		muted.toggle()
		CParsec.setMuted(muted)
		if SettingsHandler.saveSessionSettings { SettingsHandler.savedMuted = muted }
	}

		/*func genDisplaySheet() -> ActionSheet
	{
		let len:Int = 16
		var outputs = [ParsecOutput?](repeating:nil, count:len)
		ParsecGetOutputs(&outputs, UInt32(len))
		print("Listing \(outputs.count) displays")

		func getDeviceName(_ output:ParsecOutput) -> String
		{
			return withUnsafePointer(to:output.device)
			{
				$0.withMemoryRebound(to: UInt8.self, capacity:MemoryLayout.size(ofValue:$0))
				{
					String(cString:$0)
				}
			}
		}

		let buttons = outputs.enumerated().map
		{ i, output in
			Alert.Button.default(Text("\(i) - \(getDeviceName(output))"), action:{print("Selected device \(i)")})
		}
		return ActionSheet(title: Text("Select a Display:"), buttons:buttons + [Alert.Button.cancel()])
	}*/

	func disconnect(
		isBackgroundDisconnect: Bool = false,
		reason: ParsecDisconnectReason? = nil
	)
	{
		if !isBackgroundDisconnect {
			ParsecBackgroundManager.shared.disableAutoReconnect()
		}
		// Leaving the session must stop any pending connect retry, or a later
		// retry would pull the user back into the session they closed.
		ParsecConnectRunner.shared.cancel()

		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.teardown()
		}

		let disconnectReason = reason
			?? (isBackgroundDisconnect ? .backgroundExpired : (showDCAlert ? .transportFailure : .user))
		CParsec.disconnect(reason: disconnectReason)
		self.parsecViewController.glkView.cleanUp()

		parsecViewController.scrollView.zoomScale = 1.0
		parsecViewController.scrollView.contentOffset = .zero

		if let c = controller
		{
			c.setView(.main)
		}
	}
	
	func changeResolution(res: ParsecResolution) {
		// Guard against spam-tap: if a previous changeResolution is still in
		// its disconnect→reconnect dance, ignore further selections until it
		// finishes. Otherwise two overlapping connect/disconnect cycles can
		// race the SDK state machine.
		if isReconfiguring { return }

		SettingsHandler.resolution = res
		DispatchQueue.main.async {
			DataManager.model.resolutionX = res.width
			DataManager.model.resolutionY = res.height
		}

		// Parsec's host honours bitrate / FPS / output via setVideoConfig
		// user-data, but NOT resolution — that field is only read at
		// ParsecClientConnect time. To actually change the streaming
		// resolution we have to disconnect + reconnect with the new
		// ParsecClientConfig. If we don't have a peer to reconnect to
		// (shouldn't happen mid-session), fall back to just pushing the
		// user-data update.
		guard let peerID = CParsec.lastConnectedPeerID else {
			DispatchQueue.main.async {
				CParsec.updateHostVideoConfig()
			}
			return
		}

		DispatchQueue.main.async {
			// Suppress disconnect alert + show the "Switching resolution…"
			// overlay during the gap.
			self.isReconfiguring = true
			// Freeze the last decoded frame on screen instead of going black:
			// pausing the GLKViewController stops `glkView(_:drawIn:)` from
			// being called, so the framebuffer keeps its current contents.
			if let parsecGLK = self.parsecViewController.glkView as? ParsecGLKViewController {
				parsecGLK.glkViewController.isPaused = true
			}
			CParsec.disconnect(reason: .reconfigure)
		}
		// 600 ms gives the SDK enough time to fully tear down the session
		// (audio queue, poll loops, internal state) before we reconnect.
		// The user previously saw "Disconnected 20" with a 100 ms gap —
		// turns out the SDK isn't truly ready for connect() that fast.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
			// The user may have left the session in these 0.6 s; connecting
			// now would start a hidden session with no UI.
			guard self.parsecViewController.viewIfLoaded?.window != nil else {
				self.isReconfiguring = false
				return
			}
			let status = CParsec.connect(peerID, intent: .reconfigure)
			// connect() already installs the fresh ParsecClientConfig with the
			// new resolution; calling applyConfig() right after would issue a
			// redundant ParsecClientSetConfig against a just-negotiated
			// session (sometimes racy). Skip it.
			if let parsecGLK = self.parsecViewController.glkView as? ParsecGLKViewController {
				parsecGLK.glkViewController.isPaused = false
			}

			// If the reconnect didn't take (host offline, network blip),
			// surface a real error instead of leaving the user staring at
			// a frozen frame behind the spinner.
			if status != .ok && status != .connecting {
				self.isReconfiguring = false
				self.DCAlertText = "Reconnect failed (code \(status.rawValue))"
				self.showDCAlert = true
				return
			}

			// Drop the overlay a beat later — give the first new frame time
			// to arrive so the user sees content, not the spinner-over-stale.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				self.isReconfiguring = false
			}
		}
	}

	func changeBitRate(bitrate: Int) {
		DispatchQueue.main.async {
			// Model first: the Settings observer of the persisted key then sees
			// the value as already applied and doesn't push it a second time.
			DataManager.model.bitrate = bitrate
			SettingsHandler.bitrate = bitrate
			CParsec.updateHostVideoConfig()
		}
	}
	
	func toggleConstantFps() {
		DispatchQueue.main.async {
			DataManager.model.constantFps.toggle()
			constantFps = DataManager.model.constantFps
			CParsec.updateHostVideoConfig()
			if SettingsHandler.saveSessionSettings { SettingsHandler.savedConstantFps = constantFps }
		}
	}

	func toggleKeyboard() {
		DispatchQueue.main.async {
			showKeyboard.toggle()
			parsecViewController.setKeyboardVisible(showKeyboard)
		}
	}
	
	func toggleZoom() {
		DispatchQueue.main.async {
			zoomEnabled.toggle()
			parsecViewController.setZoomEnabled(zoomEnabled)
			if SettingsHandler.saveSessionSettings { SettingsHandler.savedZoomEnabled = zoomEnabled }
		}
	}
	
	func changeDisplay(displayId: String) {
		DispatchQueue.main.async {
			Diagnostics.note("display-output event=request output=\(displayId) previous=\(DataManager.model.output)")
			DataManager.model.output = displayId
			// Persist so the next connect can auto-restore this choice once
			// the host enumerates displays (user-data event 12). "none" is
			// the "Auto" pseudo-id and isn't worth remembering.
			if !SettingsHandler.saveSessionSettings {
				// "Save Session Settings" off: don't remember the display.
			} else if displayId == "none" {
				SettingsHandler.savedDisplayOutput = ""
				SettingsHandler.savedDisplayName = ""
			} else {
				SettingsHandler.savedDisplayOutput = displayId
				// Also persist the human-readable name so a regenerated id
				// next session can be matched by name.
				// Never keep the previous display's name next to the new id:
				// restore would then follow that name to the old monitor.
				SettingsHandler.savedDisplayName = DataManager.model.displayConfigs
					.first(where: { $0.id == displayId })?.label ?? ""
			}

			// S10: switching the streamed monitor makes the host re-init its
			// encoder for the new display (usually a different resolution),
			// forcing a client-side decoder reset. During that window
			// getStatusEx briefly returns non-OK, and the poll loop pops a
			// spurious "Disconnected" alert — suppressed only while
			// isReconfiguring. changeResolution raises that flag; changeDisplay
			// historically never did (D1). Bracket the switch the same way.
			self.isReconfiguring = true
			CParsec.updateHostVideoConfig()

			// No reconnect happens here, so there's no completion callback to
			// clear the flag — use a fixed window covering
			// updateHostVideoConfig's 250/450 ms resend + echo cycle plus
			// headroom. Resume the GL surface once it settles in case the
			// decoder reset blanked it (D2 — same failure class as S01, on a
			// path viewDidAppear/foreground hooks don't cover since no screen
			// transition occurs here).
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				self.parsecViewController.glkView?.resume()
				self.isReconfiguring = false
			}
		}
	}
	
	func getHostUserData() {
		let data = "".data(using: .utf8)!
		CParsec.sendUserData(type: .getVideoConfig, message: data)
		CParsec.sendUserData(type: .getAdapterInfo, message: data)
	}

}

// from https://github.com/utmapp/UTM/blob/117e3a962f2f46f7d847632d65fa7a85a2bb0cfa/Platform/iOS/VMWindowView.swift#L314
private extension View {
	func prefersPersistentSystemOverlaysHidden() -> some View {
		if #available(iOS 16, *) {
			return self.persistentSystemOverlays(.hidden)
		} else {
			return self
		}
	}
}


