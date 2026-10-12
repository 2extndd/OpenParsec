import Foundation
import SwiftUI

extension Notification.Name {
	static let parsecSettingDidChange = Notification.Name(
		"OpenParsecSettingDidChange"
	)
}

struct ParsecSettingChange: Equatable {
	let id: ParsecSettingID
}

// ponytail: a static @AppStorage caches its own last write and never sees
// writes made by SettingsView's @AppStorage instances, so once the session
// menu or Poor Network Preset had written a key, later Settings changes were
// ignored until relaunch (SettingsRuntimeTests). Read UserDefaults on every
// access instead; the stored formats match @AppStorage (raw values).
@propertyWrapper
struct SettingStorage<Value> {
	private let key: String
	private let defaultValue: Value
	private let decode: (Any) -> Value?
	private let encode: (Value) -> Any

	var wrappedValue: Value {
		get { UserDefaults.standard.object(forKey: key).flatMap(decode) ?? defaultValue }
		set { UserDefaults.standard.set(encode(newValue), forKey: key) }
	}
}

extension SettingStorage {
	init(wrappedValue: Value, _ id: ParsecSettingID) {
		self.init(key: id.rawValue, defaultValue: wrappedValue, decode: { $0 as? Value }, encode: { $0 })
	}
}

extension SettingStorage where Value: RawRepresentable {
	init(wrappedValue: Value, _ id: ParsecSettingID) {
		self.init(
			key: id.rawValue,
			defaultValue: wrappedValue,
			decode: { ($0 as? Value.RawValue).flatMap(Value.init(rawValue:)) },
			encode: { $0.rawValue }
		)
	}
}

struct SettingsHandler {
	static func notifyChanged(_ id: ParsecSettingID) {
		NotificationCenter.default.post(
			name: .parsecSettingDidChange,
			object: ParsecSettingChange(id: id)
		)
	}
	//public static var renderer:RendererType = .opengl
	@SettingStorage(.resolution) static var resolution: ParsecResolution = SettingsDefaults.resolution
	@SettingStorage(.bitrate) static var bitrate: Int = SettingsDefaults.bitrate
	@SettingStorage(.decoder) static var decoder: DecoderPref = SettingsDefaults.decoder
	@SettingStorage(.cursorMode) static var cursorMode: CursorMode = SettingsDefaults.cursorMode
	@SettingStorage(.pointerPresentationMode) static var pointerPresentationMode: PointerPresentationMode = SettingsDefaults.pointerPresentationMode
	@SettingStorage(.cursorScale) static var cursorScale: Double = SettingsDefaults.cursorScale
	@SettingStorage(.mouseSensitivity) static var mouseSensitivity: Double = SettingsDefaults.mouseSensitivity
	// Non-linear acceleration applied on top of mouseSensitivity. 0 = pure
	// linear (fastest gestures travel the same per-pixel as slow ones); up
	// to 1.5 = strong macOS-style acceleration where fast flicks travel
	// further. Surfaced as a slider in Settings → Interactivity.
	@SettingStorage(.mouseAcceleration) static var mouseAcceleration: Double = SettingsDefaults.mouseAcceleration
	@SettingStorage(.scrollSensitivity) static var scrollSensitivity: Double = SettingsDefaults.scrollSensitivity
	// Maximum synthetic trackpad glide after a meaningful flick. Zero disables
	// the client tail; the bound keeps it controllable when iPadOS cannot expose
	// a contact-only Magic Keyboard brake event.
	@SettingStorage(.scrollGlideDuration) static var scrollGlideDuration: Double = SettingsDefaults.scrollGlideDuration
	// When true (default), trackpad scroll direction matches what iPad/macOS
	// call "natural scrolling" — swipe down moves content down. Flip to false
	// if you want classic mouse-wheel direction.
	@SettingStorage(.naturalScrolling) static var naturalScrolling: Bool = SettingsDefaults.naturalScrolling
	// Best-effort iPadOS system-shortcut capture via UIKeyCommand registry
	// with .wantsPriorityOverSystemBehavior (iOS 15+). Catches Cmd+letter
	// combinations the iPad shell would otherwise eat. Cmd+Space, Cmd+H,
	// Globe key, and swipe-up gestures stay system-level — those cannot be
	// intercepted from a sandboxed iPad app.
	@SettingStorage(.captureSystemKeys) static var captureSystemKeys: Bool = SettingsDefaults.captureSystemKeys
	// The legacy bidirectional "windowsHostKeyboardRemap" Bool was replaced by
	// the explicit windowsKeyboardMode picker below. The property is gone; the
	// raw defaults key is still read once by migrateWindowsKeyboardRemapIfNeeded
	// to seed the new mode on first launch after the upgrade.
	@SettingStorage(.windowsKeyboardMode) static var windowsKeyboardMode: WindowsKeyboardMode = SettingsDefaults.windowsKeyboardMode
	@SettingStorage(.hostShortcutToolbarMode) static var hostShortcutToolbarMode: HostShortcutToolbarMode = SettingsDefaults.hostShortcutToolbarMode
	@SettingStorage(.noOverlay) static var noOverlay: Bool = SettingsDefaults.noOverlay
	// Q1: previously shared the "cursorScale" key with the Double cursorScale
	// above — a Bool write coerced cursorScale (false → 0 = invisible cursor)
	// and vice versa. Own key now; migrateLegacyStatusBarKeyIfNeeded() seeds it
	// and clamps any corrupted cursorScale on first launch after the upgrade.
	@SettingStorage(.hideStatusBar) static var hideStatusBar: Bool = SettingsDefaults.hideStatusBar
	@SettingStorage(.rightClickPosition) static var rightClickPosition: RightClickPosition = SettingsDefaults.rightClickPosition
	@SettingStorage(.preferredFramesPerSecond) static var preferredFramesPerSecond: Int = SettingsDefaults.preferredFramesPerSecond // 0 = use device max (ProMotion). Default was 60 — that capped 120 Hz iPads at half their refresh, doubling glass-to-glass present latency.
	@SettingStorage(.decoderCompatibility) static var decoderCompatibility: Bool = SettingsDefaults.decoderCompatibility // Enable for stutter issues on some devices
	@SettingStorage(.showKeyboardButton) static var showKeyboardButton: Bool = SettingsDefaults.showKeyboardButton

	// When the iPad's hardware keyboard layout changes (Caps Lock / Ctrl+Space
	// on Magic Keyboard), fire a hotkey at the host so the host's input source
	// switches in lock-step. Eliminates the "wrong characters after switching
	// language" problem people hit on iPad ↔ Mac Parsec sessions.
	@SettingStorage(.syncKeyboardLayout) static var syncKeyboardLayout: Bool = SettingsDefaults.syncKeyboardLayout
	@SettingStorage(.layoutSyncHotkey) static var layoutSyncHotkey: LayoutSyncHotkey = SettingsDefaults.layoutSyncHotkey

	// When true, pressing Ctrl+Shift *alone* (no other key in between) fires
	// Cmd+Space at the host — the macOS "switch input source" / Spotlight chord
	// the iPad shell otherwise swallows. Holding Ctrl+Shift and then pressing
	// any other key (e.g. Ctrl+Shift+Arrow to extend a selection) is forwarded
	// normally and does NOT fire the emulation. Off by default; intended for Mac
	// hosts. Not auto-gated on host OS yet because host-OS detection (S04) still
	// resolves to .unknown until the Int→OS mapping is discovered empirically —
	// so this stays a deliberate manual opt-in.
	@SettingStorage(.ctrlShiftEmulatesCmdSpace) static var ctrlShiftEmulatesCmdSpace: Bool = SettingsDefaults.ctrlShiftEmulatesCmdSpace

	// When true, pressing a *bare* backtick/grave (`) — no Cmd/Ctrl/Alt/Shift —
	// fires Cmd+Space at the host instead of sending the grave scancode. This is
	// a manual language-switch macro: the physical Cmd+Space is swallowed by
	// iPadOS (Spotlight) and never reaches the host, but a backtick is an
	// ordinary key we can intercept and re-emit as host scancodes. Shift+`
	// (tilde) and Cmd+` are untouched because any modifier disqualifies the
	// remap. Off by default; turning it on means you can no longer type a literal
	// backtick into the host while connected. Intended for Mac hosts whose
	// "Select previous input source" / Spotlight is bound to ⌘Space.
	@SettingStorage(.backtickEmulatesCmdSpace) static var backtickEmulatesCmdSpace: Bool = SettingsDefaults.backtickEmulatesCmdSpace

	@SettingStorage(.saveSessionSettings) static var saveSessionSettings: Bool = SettingsDefaults.saveSessionSettings
	@SettingStorage(.savedZoomEnabled) static var savedZoomEnabled: Bool = SettingsDefaults.savedZoomEnabled
	@SettingStorage(.savedConstantFps) static var savedConstantFps: Bool = SettingsDefaults.savedConstantFps
	@SettingStorage(.savedMuted) static var savedMuted: Bool = SettingsDefaults.savedMuted
	// Remember which display the user picked last; restored on the next
	// connect once the host enumerates its displays (user-data event 12).
	// The id is the primary key; the name (e.g. "Built-in Retina Display ...")
	// is a fallback because Parsec sometimes regenerates display ids between
	// connects for the same physical display.
	@SettingStorage(.savedDisplayOutput) static var savedDisplayOutput: String = SettingsDefaults.savedDisplayOutput
	@SettingStorage(.savedDisplayName) static var savedDisplayName: String = SettingsDefaults.savedDisplayName

	// Q1 one-time migration. hideStatusBar used to (incorrectly) share the
	// "cursorScale" UserDefaults key, so the two settings corrupted each other.
	// On the first launch after the fix, seed the new "hideStatusBar" key with
	// its original default and clamp any cursorScale value that a Bool write
	// may have driven out of range (notably 0 = invisible cursor). Call once at
	// app launch, before any UI reads these values.
	static func migrateLegacyStatusBarKeyIfNeeded() {
		let defaults = UserDefaults.standard
		// Absence of the new key == migration not yet run.
		guard defaults.object(forKey: "hideStatusBar") == nil else { return }
		// The shared value can't be split back into two settings, so restore
		// the original hideStatusBar default (true) and sanitize cursorScale.
		defaults.set(true, forKey: "hideStatusBar")
		if defaults.object(forKey: "cursorScale") != nil {
			let raw = defaults.double(forKey: "cursorScale")
			let clamped = min(max(raw, 0.1), 4.0)
			if clamped != raw {
				defaults.set(clamped, forKey: "cursorScale")
			}
		}
	}

	// S10 one-way migration. The old bidirectional "windowsHostKeyboardRemap"
	// Bool becomes the explicit windowsKeyboardMode picker: an enabled legacy
	// remap maps to Command-as-Control; anything else stays Direct HID. Runs
	// once, before any UI reads windowsKeyboardMode.
	static func migrateWindowsKeyboardRemapIfNeeded() {
		let defaults = UserDefaults.standard
		guard defaults.object(forKey: ParsecSettingID.windowsKeyboardMode.rawValue) == nil else { return }
		let legacyEnabled = defaults.bool(forKey: "windowsHostKeyboardRemap")
		defaults.set(
			(legacyEnabled ? WindowsKeyboardMode.commandAsControl : .direct).rawValue,
			forKey: ParsecSettingID.windowsKeyboardMode.rawValue
		)
	}

	static func migratePointerPresentationModeIfNeeded(
		defaults: UserDefaults = .standard
	) {
		let key = ParsecSettingID.pointerPresentationMode.rawValue
		guard defaults.object(forKey: key) == nil,
		      defaults.object(forKey: "localCursorOverlay") != nil else { return }
		let mode: PointerPresentationMode = defaults.bool(
			forKey: "localCursorOverlay"
		) ? .captured : .native
		defaults.set(mode.rawValue, forKey: key)
		defaults.removeObject(forKey: "localCursorOverlay")
	}

	// The old default sent ⌃Space, but macOS input-source switching is
	// usually ⌘Space (and Win+Space on Windows, which ⌘Space maps to). Move
	// users still on the old default once; later explicit choices stick.
	static func migrateLayoutSyncHotkeyIfNeeded(defaults: UserDefaults = .standard) {
		let flag = "layoutSyncHotkeyMigratedToCmdSpace"
		guard !defaults.bool(forKey: flag) else { return }
		defaults.set(true, forKey: flag)
		let key = ParsecSettingID.layoutSyncHotkey.rawValue
		if defaults.object(forKey: key) == nil
			|| defaults.integer(forKey: key) == LayoutSyncHotkey.ctrlSpace.rawValue {
			defaults.set(LayoutSyncHotkey.cmdSpace.rawValue, forKey: key)
		}
	}

	static func migrateHostShortcutToolbarIfNeeded(
		defaults: UserDefaults = .standard
	) {
		let key = ParsecSettingID.hostShortcutToolbarMode.rawValue
		guard defaults.object(forKey: key) == nil else { return }
		let macObject = defaults.object(forKey: "showMacShortcutButtons")
		let windowsObject = defaults.object(forKey: "showWindowsShortcutButtons")
		let mode = ParsecHostShortcutToolbarPolicy.migrate(
			showMac: macObject.map { _ in defaults.bool(forKey: "showMacShortcutButtons") },
			showWindows: windowsObject.map { _ in defaults.bool(forKey: "showWindowsShortcutButtons") }
		)
		defaults.set(mode.rawValue, forKey: key)
		defaults.removeObject(forKey: "showMacShortcutButtons")
		defaults.removeObject(forKey: "showWindowsShortcutButtons")
	}

	// Explicit poor-network preset. It writes the same independently persisted
	// controls a user can adjust later; there is no stale umbrella Bool claiming
	// the profile remains active after an override.
	// "Windows Keyboard Mode" must never remap ⌘ on a confirmed macOS host.
	static var effectiveWindowsKeyboardMode: WindowsKeyboardMode {
		CParsec.hostOS == .macos ? .direct : windowsKeyboardMode
	}

	static func applyPoorNetworkPreset() {
		// Manual only. Cuts what crosses the link: resolution, bitrate, codec.
		// (Local display refresh is unrelated to the network, so untouched.)
		resolution = .r1280x720_16_9     // ~4x fewer pixels than the iPad's native size
		decoder = .h265                  // more quality per capped bit
		// Never touch noOverlay here: hiding the overlay removes Disconnect,
		// Bitrate and Resolution from the session with no way back.
		decoderCompatibility = false     // compat decode path adds latency
		bitrate = 5                      // poor-network ceiling (Mbps)
		// Constant FPS makes the host send 60 fps of an unchanged screen; off,
		// a static desktop costs almost nothing. Live session too (next push).
		savedConstantFps = false
		DataManager.model.constantFps = false
		Diagnostics.note(
			"setting-preset id=poor-network result=applied reconnect=resolution,decoder,compatibility"
		)
	}

}
