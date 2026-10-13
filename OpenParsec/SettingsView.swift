import SwiftUI

struct SettingsView:View
{
	@Binding var visible: Bool

	//@State var renderer:RendererType = SettingsHandler.renderer
	@AppStorage(ParsecSettingID.resolution.rawValue) var resolution: ParsecResolution = SettingsDefaults.resolution
	@AppStorage(ParsecSettingID.decoder.rawValue) var decoder: DecoderPref = SettingsDefaults.decoder
	@AppStorage(ParsecSettingID.cursorMode.rawValue) var cursorMode: CursorMode = SettingsDefaults.cursorMode
	@AppStorage(ParsecSettingID.pointerPresentationMode.rawValue) var pointerPresentationMode: PointerPresentationMode = SettingsDefaults.pointerPresentationMode
	@AppStorage(ParsecSettingID.cursorScale.rawValue) var cursorScale: Double = SettingsDefaults.cursorScale
	@AppStorage(ParsecSettingID.mouseSensitivity.rawValue) var mouseSensitivity: Double = SettingsDefaults.mouseSensitivity
	@AppStorage(ParsecSettingID.mouseAcceleration.rawValue) var mouseAcceleration: Double = SettingsDefaults.mouseAcceleration
	@AppStorage(ParsecSettingID.scrollSensitivity.rawValue) var scrollSensitivity: Double = SettingsDefaults.scrollSensitivity
	@AppStorage(ParsecSettingID.scrollGlideDuration.rawValue) var scrollGlideDuration: Double = SettingsDefaults.scrollGlideDuration
	@AppStorage(ParsecSettingID.naturalScrolling.rawValue) var naturalScrolling: Bool = SettingsDefaults.naturalScrolling
	@AppStorage(ParsecSettingID.captureSystemKeys.rawValue) var captureSystemKeys: Bool = SettingsDefaults.captureSystemKeys
	@AppStorage(ParsecSettingID.hostShortcutToolbarMode.rawValue) var hostShortcutToolbarMode: HostShortcutToolbarMode = SettingsDefaults.hostShortcutToolbarMode
	@AppStorage(ParsecSettingID.windowsKeyboardMode.rawValue) var windowsKeyboardMode: WindowsKeyboardMode = SettingsDefaults.windowsKeyboardMode
	@AppStorage(ParsecSettingID.noOverlay.rawValue) var noOverlay: Bool = SettingsDefaults.noOverlay
	@AppStorage(ParsecSettingID.hideStatusBar.rawValue) var hideStatusBar: Bool = SettingsDefaults.hideStatusBar
	@AppStorage(ParsecSettingID.rightClickPosition.rawValue) var rightClickPosition: RightClickPosition = SettingsDefaults.rightClickPosition
	@AppStorage(ParsecSettingID.preferredFramesPerSecond.rawValue) var preferredFramesPerSecond: Int = SettingsDefaults.preferredFramesPerSecond // 0 = use device max (ProMotion)
	@AppStorage(ParsecSettingID.decoderCompatibility.rawValue) var decoderCompatibility: Bool = SettingsDefaults.decoderCompatibility // Enable for stutter issues on some devices
	@AppStorage(ParsecSettingID.showKeyboardButton.rawValue) var showKeyboardButton: Bool = SettingsDefaults.showKeyboardButton
	@AppStorage(ParsecSettingID.syncKeyboardLayout.rawValue) var syncKeyboardLayout: Bool = SettingsDefaults.syncKeyboardLayout
	@AppStorage(ParsecSettingID.layoutSyncHotkey.rawValue) var layoutSyncHotkey: LayoutSyncHotkey = SettingsDefaults.layoutSyncHotkey
	@AppStorage(ParsecSettingID.ctrlShiftEmulatesCmdSpace.rawValue) var ctrlShiftEmulatesCmdSpace: Bool = SettingsDefaults.ctrlShiftEmulatesCmdSpace
	@AppStorage(ParsecSettingID.backtickEmulatesCmdSpace.rawValue) var backtickEmulatesCmdSpace: Bool = SettingsDefaults.backtickEmulatesCmdSpace
	@AppStorage(ParsecSettingID.saveSessionSettings.rawValue) var saveSessionSettings: Bool = SettingsDefaults.saveSessionSettings
	@AppStorage(ParsecSettingID.bitrate.rawValue) var bitrate: Int = SettingsDefaults.bitrate
	@AppStorage(ParsecSettingID.macStreamScale.rawValue) var macStreamScale: MacStreamScale = SettingsDefaults.macStreamScale
	@State private var crashCopied: Bool = false
	@State private var diagCopied: Bool = false
	@State private var keyProbeStarted: Bool = false
	@State private var showConnectionTest: Bool = false
	
	let resolutionChoices: [Choice<ParsecResolution>]

	init(visible: Binding<Bool>) {
		_visible = visible
		var tmp: [Choice<ParsecResolution>] = []
		for res in ParsecResolution.resolutions {
			tmp.append(Choice(res.desc, res))
		}
		resolutionChoices = tmp
	}
	
	var body: some View
	{
		ZStack()
		{
			if (visible)
			{
				// Background
				Rectangle()
					.fill(Color.init(red:0, green:0, blue:0, opacity:0.67))
					.edgesIgnoringSafeArea(.all)
			}
		}
		.animation(.linear(duration:0.24))

		ZStack()
		{
			if (visible)
			{
				// Main controls
				VStack()
				{
					// Navigation controls
					ZStack()
					{
						Rectangle()
							.fill(Color("BackgroundTab"))
							.frame(height:52)
							.shadow(color:Color("Shading"), radius:4, y:6)
						ZStack()
						{
							HStack()
							{
								Button(action: saveAndExit, label:{ Image(systemName:"xmark").scaleEffect(x:-1) })
								 .padding()
								Spacer()
							}
							Text("Settings")
								.multilineTextAlignment(.center)
								.foregroundColor(Color("Foreground"))
								.font(.system(size:20, weight:.medium))
							Spacer()
						}
						.foregroundColor(Color("AccentColor"))
					}
					.zIndex(1)

					ScrollView()
					{
						CatTitle("Stream")
						CatList()
						{
							CatItem("Resolution")
							{
								MultiPicker(selection: $resolution, options:resolutionChoices)
							}
							CatItem("Mac Stream Size (Mac helper)")
							{
								MultiPicker(selection: $macStreamScale, options:
									MacStreamScale.allCases.map { Choice($0.label(native: nil), $0) })
							}
							CatItem("Max Bitrate")
							{
								// Values above maxSafeHostBitrate crash the SDK decoder on
								// high-res H.265 keyframes (see ParsecVideoSuspendPolicy), so
								// they are not offered; the send path clamps as a backstop.
								MultiPicker(selection: $bitrate, options:
								[Choice("Host Default (max \(ParsecVideoSuspendPolicy.maxSafeHostBitrate))", 0)]
								+ ParsecResolution.bitrates
									.filter { $0 <= ParsecVideoSuspendPolicy.maxSafeHostBitrate }
									.map { Choice("\($0) Mbps", $0) })
							}
							CatItem("Decoder")
							{
								MultiPicker(selection: $decoder, options:
								[
								Choice("H.264", DecoderPref.h264),
								Choice("Prefer H.265", DecoderPref.h265)
								])
							}
							CatItem("Decoder Compatibility (fixes stutter)")
							{
								Toggle("", isOn:$decoderCompatibility)
								.frame(width:80)
							}
							CatItem("Local Display Refresh")
							{
								MultiPicker(selection: $preferredFramesPerSecond, options:
								[
								Choice("Auto (\(UIScreen.main.maximumFramesPerSecond) Hz)", 0),
								Choice("120 FPS", 120),
								Choice("60 FPS", 60),
								Choice("30 FPS", 30)
								])
							}
							CatItem("Poor Network Preset")
							{
								Button("Apply") {
								SettingsHandler.applyPoorNetworkPreset()
								}
							}
						}
						CatTitle("Pointer & Trackpad")
						CatList()
						{
							CatItem("Pointer Mode")
							{
								MultiPicker(selection:$pointerPresentationMode, options:
								[
								Choice("Native (iPad pointer)", PointerPresentationMode.native),
								Choice("Captured (games)", PointerPresentationMode.captured)
								])
							}
							CatItem("Natural Scrolling")
							{
								Toggle("", isOn:$naturalScrolling)
								.frame(width:80)
							}
							CatItem("Scroll Speed")
							{
								Slider(value: $scrollSensitivity, in:0.1...4, step:0.1)
								.frame(width: 200)
								Text(String(format: "%.1f", scrollSensitivity))
							}
							CatItem("Scroll Glide")
							{
								Slider(value: $scrollGlideDuration, in:0...1.2, step:0.1)
								.frame(width: 200)
								Text(
								scrollGlideDuration == 0
								? "Stops immediately"
								: String(format: "Up to %.1f s", scrollGlideDuration)
								)
							}
							CatItem("Pointer Speed (Captured mode)")
							{
								Slider(value: $mouseSensitivity, in:0.1...4, step:0.1)
								.frame(width: 200)
								Text(String(format: "%.1f", mouseSensitivity))
							}
							CatItem("Acceleration (Captured mode)")
							{
								Slider(value: $mouseAcceleration, in:0...1.5, step:0.05)
								.frame(width: 200)
								Text(String(format: "%.2f", mouseAcceleration))
							}
						}
						CatTitle("Touchscreen")
						CatList()
						{
							CatItem("Finger Mode")
							{
								MultiPicker(selection:$cursorMode, options:
								[
								Choice("Touchpad", CursorMode.touchpad),
								Choice("Direct", CursorMode.direct)
								])
							}
							CatItem("Two-Finger Tap Right Click At")
							{
								MultiPicker(selection:$rightClickPosition, options:
								[
								Choice("First Finger", RightClickPosition.firstFinger),
								Choice("Middle", RightClickPosition.middle),
								Choice("Second Finger", RightClickPosition.secondFinger)
								])
							}
							CatItem("Cursor Size")
							{
								Slider(value: $cursorScale, in:0.1...4, step:0.1)
								.frame(width: 200)
								Text(String(format: "%.1f", cursorScale))
							}
						}
						CatTitle("Keyboard")
						CatList()
						{
							CatItem("Capture ⌘ Shortcuts")
							{
								Toggle("", isOn:$captureSystemKeys)
								.frame(width:80)
							}
							CatItem("Shortcut Buttons Above Keyboard")
							{
								MultiPicker(selection:$hostShortcutToolbarMode, options:
								[
								Choice("Automatic", HostShortcutToolbarMode.automatic),
								Choice("macOS", HostShortcutToolbarMode.macOS),
								Choice("Windows", HostShortcutToolbarMode.windows),
								Choice("Both", HostShortcutToolbarMode.both),
								Choice("Off", HostShortcutToolbarMode.off)
								])
							}
							CatItem("Windows Host: ⌘ Key Sends")
							{
								MultiPicker(selection:$windowsKeyboardMode, options:
								[
								Choice("Win key", WindowsKeyboardMode.direct),
								Choice("Ctrl (⌘C = copy)", WindowsKeyboardMode.commandAsControl)
								])
							}
						}
						CatTitle("Language Switching")
						CatList()
						{
							CatItem("Follow iPad Language (Globe)")
							{
								Toggle("", isOn:$syncKeyboardLayout)
								.frame(width:80)
							}
							CatItem("Host Switch Shortcut")
							{
								MultiPicker(selection:$layoutSyncHotkey, options:
								[
								Choice("⌘ Space (Mac) / Win Space (PC)", LayoutSyncHotkey.cmdSpace),
								Choice("⌃ Space", LayoutSyncHotkey.ctrlSpace),
								Choice("⌃ + ⇧ (macOS alt)", LayoutSyncHotkey.ctrlShift),
																Choice("⌥ + Space", LayoutSyncHotkey.altSpace),
								Choice("Alt + Shift (Windows)", LayoutSyncHotkey.altShift),
								Choice("Off", LayoutSyncHotkey.none)
								])
							}
							CatItem("⌃⇧ Sends ⌘Space (Mac host)")
							{
								Toggle("", isOn:$ctrlShiftEmulatesCmdSpace)
								.frame(width:80)
							}
							CatItem("` Key Sends ⌘Space (Mac host)")
							{
								Toggle("", isOn:$backtickEmulatesCmdSpace)
								.frame(width:80)
							}
						}
						CatTitle("Interface")
						CatList()
						{
							CatItem("Show Keyboard Button")
							{
								Toggle("", isOn:$showKeyboardButton)
								.frame(width:80)
							}
							CatItem("Hide Status Bar")
							{
								Toggle("", isOn:$hideStatusBar)
								.frame(width:80)
							}
							CatItem("Hide Session Button")
							{
								Toggle("", isOn:$noOverlay)
								.frame(width:80)
							}
							CatItem("Remember Session Choices")
							{
								Toggle("", isOn:$saveSessionSettings)
								.frame(width:80)
							}
						}
						CatTitle("Diagnostics")
						CatList()
						{
							CatItem("Connection Test (VPN, UDP, NAT, IPv6)")
							{
								Button("Run") { showConnectionTest = true }
							}
							CatItem("Keyboard Shortcut Probe (60 s)")
							{
								Button(keyProbeStarted ? "Running — press shortcuts" : "Start") {
									GamepadController.startKeyboardProbe()
									keyProbeStarted = true
								}
							}
							CatItem("Copy Diagnostics Log")
							{
								Button(action: {
								if let diag = Diagnostics.peek() {
								UIPasteboard.general.string = diag
								diagCopied = true
								} else {
								UIPasteboard.general.string = "(no diagnostics recorded)"
								diagCopied = true
								}
								}) {
								Text(diagCopied ? "Copied!" : (!Diagnostics.hasLog ? "None" : "Copy"))
								.foregroundColor(!Diagnostics.hasLog ? .gray : Color("AccentColor"))
								}
							}
							CatItem("Copy Last Crash Log")
							{
								Button(action: {
								if let crash = CrashReporter.peek() {
								UIPasteboard.general.string = crash
								crashCopied = true
								} else {
								UIPasteboard.general.string = "(no crash recorded)"
								crashCopied = true
								}
								}) {
								Text(crashCopied ? "Copied!" : (!CrashReporter.hasLog ? "None" : "Copy"))
								.foregroundColor(!CrashReporter.hasLog ? .gray : Color("AccentColor"))
								}
							}
						}
						Text(getVersionInfo())
							.multilineTextAlignment(.center)
							.opacity(0.5)
							.padding()
					}
                    .foregroundColor(Color("Foreground"))
				}
				.background(Rectangle().fill(Color("BackgroundGray")))
				.cornerRadius(8)
				.padding()
				.animation(.none)
			}
		}
        .preferredColorScheme(appScheme)
		.sheet(isPresented: $showConnectionTest) { ConnectionTestView() }
		.scaleEffect(visible ? 1 : 0, anchor:.zero)
		.animation(.easeInOut(duration:0.24))
		.onChange(of: syncKeyboardLayout) { _ in
			SettingsHandler.notifyChanged(.syncKeyboardLayout)
		}
		.onChange(of: layoutSyncHotkey) { _ in
			SettingsHandler.notifyChanged(.layoutSyncHotkey)
		}
		.onChange(of: captureSystemKeys) { _ in
			SettingsHandler.notifyChanged(.captureSystemKeys)
		}
		.onChange(of: hostShortcutToolbarMode) { _ in
			SettingsHandler.notifyChanged(.hostShortcutToolbarMode)
		}
		.onChange(of: windowsKeyboardMode) { _ in
			SettingsHandler.notifyChanged(.windowsKeyboardMode)
		}
		.onChange(of: preferredFramesPerSecond) { _ in
			SettingsHandler.notifyChanged(.preferredFramesPerSecond)
		}
		.onChange(of: pointerPresentationMode) { _ in
			SettingsHandler.notifyChanged(.pointerPresentationMode)
		}
		.onChange(of: bitrate) { _ in
			SettingsHandler.notifyChanged(.bitrate)
		}
		.onChange(of: macStreamScale) { _ in
			SettingsHandler.notifyChanged(.macStreamScale)
		}
		.onAppear {
			// Pull a value saved before the safety cap down to the ceiling so the
			// picker shows a selectable option and the host is never asked for more.
			if bitrate > ParsecVideoSuspendPolicy.maxSafeHostBitrate {
				bitrate = ParsecVideoSuspendPolicy.maxSafeHostBitrate
			}
		}
	}
	
	func saveAndExit()
	{
		//SettingsHandler.renderer = renderer
		visible = false
	}
	
	func getVersionInfo() -> String {
		let info = Bundle.main.infoDictionary
		let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown version"
		let commit = info?["GitCommitInfo"] as? String ?? "Unknown commit"
		return "Version \(version)-\(commit)"
	}
}

struct SettingsView_Previews:PreviewProvider
{
	@State static var value: Bool = true

	static var previews: some View
	{
		SettingsView(visible:$value)
	}
}
