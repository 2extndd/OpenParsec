import Foundation

/// Stable persisted setting identifiers. These are the only UserDefaults keys
/// application code and Settings UI should reference.
enum ParsecSettingID: String, CaseIterable {
    case resolution
    case bitrate
    case decoder
    case cursorMode
    case pointerPresentationMode
    case cursorScale
    case mouseSensitivity
    case mouseAcceleration
    case scrollSensitivity
    case scrollGlideDuration
    case naturalScrolling
    case captureSystemKeys
    case windowsKeyboardMode
    case hostShortcutToolbarMode
    case noOverlay
    case hideStatusBar
    case rightClickPosition
    case preferredFramesPerSecond
    case decoderCompatibility
    case showKeyboardButton
    case syncKeyboardLayout
    case layoutSyncHotkey
    case ctrlShiftEmulatesCmdSpace
    case backtickEmulatesCmdSpace
    case saveSessionSettings
    case savedZoomEnabled
    case savedConstantFps
    case savedMuted
    case savedDisplayOutput
    case savedDisplayName
}

/// Canonical defaults shared by runtime and SwiftUI AppStorage wrappers.
enum SettingsDefaults {
    static let resolution: ParsecResolution = .client
    static let bitrate = 0
    static let decoder: DecoderPref = .h264
    static let cursorMode: CursorMode = .touchpad
    static let pointerPresentationMode: PointerPresentationMode = .native
    static let cursorScale = 0.5
    static let mouseSensitivity = 1.0
    static let mouseAcceleration = 0.0
    static let scrollSensitivity = 1.0
    static let scrollGlideDuration = 0.6
    static let naturalScrolling = true
    static let captureSystemKeys = true
    static let windowsKeyboardMode: WindowsKeyboardMode = .direct
    static let hostShortcutToolbarMode: HostShortcutToolbarMode = .automatic
    static let noOverlay = false
    static let hideStatusBar = true
    static let rightClickPosition: RightClickPosition = .firstFinger
    static let preferredFramesPerSecond = 0
    static let decoderCompatibility = false
    static let showKeyboardButton = true
    static let syncKeyboardLayout = true
    static let layoutSyncHotkey: LayoutSyncHotkey = .cmdSpace
    static let ctrlShiftEmulatesCmdSpace = false
    static let backtickEmulatesCmdSpace = false
    static let saveSessionSettings = true
    static let savedZoomEnabled = false
    static let savedConstantFps = false
    static let savedMuted = false
    static let savedDisplayOutput = ""
    static let savedDisplayName = ""

    static func value(for id: ParsecSettingID) -> ParsecSettingDefault {
        switch id {
        case .resolution: ParsecSettingDefault(resolution)
        case .bitrate: ParsecSettingDefault(bitrate)
        case .decoder: ParsecSettingDefault(decoder)
        case .cursorMode: ParsecSettingDefault(cursorMode)
        case .pointerPresentationMode: ParsecSettingDefault(pointerPresentationMode)
        case .cursorScale: ParsecSettingDefault(cursorScale)
        case .mouseSensitivity: ParsecSettingDefault(mouseSensitivity)
        case .mouseAcceleration: ParsecSettingDefault(mouseAcceleration)
        case .scrollSensitivity: ParsecSettingDefault(scrollSensitivity)
        case .scrollGlideDuration: ParsecSettingDefault(scrollGlideDuration)
        case .naturalScrolling: ParsecSettingDefault(naturalScrolling)
        case .captureSystemKeys: ParsecSettingDefault(captureSystemKeys)
        case .windowsKeyboardMode: ParsecSettingDefault(windowsKeyboardMode)
        case .hostShortcutToolbarMode: ParsecSettingDefault(hostShortcutToolbarMode)
        case .noOverlay: ParsecSettingDefault(noOverlay)
        case .hideStatusBar: ParsecSettingDefault(hideStatusBar)
        case .rightClickPosition: ParsecSettingDefault(rightClickPosition)
        case .preferredFramesPerSecond: ParsecSettingDefault(preferredFramesPerSecond)
        case .decoderCompatibility: ParsecSettingDefault(decoderCompatibility)
        case .showKeyboardButton: ParsecSettingDefault(showKeyboardButton)
        case .syncKeyboardLayout: ParsecSettingDefault(syncKeyboardLayout)
        case .layoutSyncHotkey: ParsecSettingDefault(layoutSyncHotkey)
        case .ctrlShiftEmulatesCmdSpace: ParsecSettingDefault(ctrlShiftEmulatesCmdSpace)
        case .backtickEmulatesCmdSpace: ParsecSettingDefault(backtickEmulatesCmdSpace)
        case .saveSessionSettings: ParsecSettingDefault(saveSessionSettings)
        case .savedZoomEnabled: ParsecSettingDefault(savedZoomEnabled)
        case .savedConstantFps: ParsecSettingDefault(savedConstantFps)
        case .savedMuted: ParsecSettingDefault(savedMuted)
        case .savedDisplayOutput: ParsecSettingDefault(savedDisplayOutput)
        case .savedDisplayName: ParsecSettingDefault(savedDisplayName)
        }
    }
}

/// Comparable type-erased representation used by registry parity tests and
/// content-safe diagnostics. Runtime code continues to use typed defaults.
struct ParsecSettingDefault: Equatable {
    let typeName: String
    let valueDescription: String

    init<Value>(_ value: Value) {
        typeName = String(reflecting: Value.self)
        valueDescription = String(describing: value)
    }
}

/// How a persisted setting reaches the running session.
enum ParsecSettingApplication: String, Equatable {
    /// Takes effect immediately on the live session.
    case live
    /// Only takes effect on the next connect/reconnect.
    case reconnect
    /// Session-saved state restored at connect time; not applied mid-session.
    case restoredOnConnect = "restored-on-connect"
}

/// Which remote host(s) a setting meaningfully affects.
enum ParsecSettingHostApplicability: String, Equatable {
    case any
    case macOS = "macos"
    case windows
}

/// Whether a persisted key is a user-facing control or internal saved state.
enum ParsecSettingKind: String, Equatable {
    /// Exposed as a control in SettingsView.
    case userVisibleControl = "user-visible-control"
    /// Session-saved state with no direct SettingsView control (restored at
    /// connect time or driven indirectly by another control).
    case sessionSavedState = "session-saved-state"
}

/// One authoritative contract entry for a persisted setting.
struct ParsecSettingDescriptor: Equatable {
    let id: ParsecSettingID
    let defaultValue: ParsecSettingDefault
    /// UserDefaults / @AppStorage key.
    var key: String { id.rawValue }
    let kind: ParsecSettingKind
    /// True when SettingsView renders a control bound to this key.
    let hasUIControl: Bool
    /// Short human summary of what consumes the value at runtime.
    let consumer: String
    let host: ParsecSettingHostApplicability
    let application: ParsecSettingApplication
    /// Note describing invalid/conflicting-combination handling, or "" when none.
    let invalidCombinationNote: String

    init(
        id: ParsecSettingID,
        kind: ParsecSettingKind,
        hasUIControl: Bool,
        consumer: String,
        host: ParsecSettingHostApplicability,
        application: ParsecSettingApplication,
        invalidCombinationNote: String
    ) {
        self.id = id
        defaultValue = SettingsDefaults.value(for: id)
        self.kind = kind
        self.hasUIControl = hasUIControl
        self.consumer = consumer
        self.host = host
        self.application = application
        self.invalidCombinationNote = invalidCombinationNote
    }
}

/// The single source of truth mapping every persisted setting to its UI,
/// runtime consumer, host applicability, application timing, and invalid-
/// combination handling. A completeness test enforces a two-way match against
/// the real @AppStorage keys so no key is undocumented and no descriptor
/// names a dead key.
enum ParsecSettingsContract {
    static let descriptors: [ParsecSettingDescriptor] = [
        ParsecSettingDescriptor(
            id: .resolution,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Requested client/host resolution applied to the SDK config.",
            host: .any,
            application: .reconnect,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .bitrate,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Encoder bitrate ceiling (Mbps), 0 = host default; Settings picker, Poor Network Preset, or in-session control.",
            host: .any,
            application: .live,
            invalidCombinationNote: "Set to a poor-network ceiling by the Poor Network Preset; session controls can override it afterward."
        ),
        ParsecSettingDescriptor(
            id: .decoder,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "H.264 vs preferred H.265 decode path in the SDK config.",
            host: .any,
            application: .reconnect,
            invalidCombinationNote: "Set to H.265 by the Poor Network Preset; applies on reconnect and remains overridable."
        ),
        ParsecSettingDescriptor(
            id: .cursorMode,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Touchpad vs direct mouse-movement mapping in the pointer path.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .pointerPresentationMode,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Native unlocked vs captured relative pointer presentation.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .cursorScale,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Local cursor overlay scale (0.1–4.0).",
            host: .any,
            application: .live,
            invalidCombinationNote: "Clamped to 0.1–4.0 on legacy-key migration to undo an earlier shared-key corruption."
        ),
        ParsecSettingDescriptor(
            id: .mouseSensitivity,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Linear pointer-movement multiplier.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .mouseAcceleration,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Non-linear acceleration added on top of mouseSensitivity.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .scrollSensitivity,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Scroll delta multiplier in the wheel transform.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .scrollGlideDuration,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Maximum client-generated trackpad glide duration (0.0–1.2 seconds).",
            host: .any,
            application: .live,
            invalidCombinationNote: "Zero disables synthetic glide; contact-only Magic Keyboard braking is not observable through UIKit."
        ),
        ParsecSettingDescriptor(
            id: .naturalScrolling,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Scroll direction (natural vs classic) in the wheel transform.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .captureSystemKeys,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Best-effort UIKeyCommand priority capture of iPad system chords.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .windowsKeyboardMode,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Direct HID vs one-way Command-as-Control mapping applied in ParsecSDKBridge.",
            host: .windows,
            application: .live,
            invalidCombinationNote: "Migrated one-way from the legacy windowsHostKeyboardRemap bool."
        ),
        ParsecSettingDescriptor(
            id: .hostShortcutToolbarMode,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Selects automatic host-specific, Mac, Windows, combined, or hidden shortcut toolbar alternatives.",
            host: .any,
            application: .live,
            invalidCombinationNote: "Migrated one-way from the legacy showMacShortcutButtons and showWindowsShortcutButtons booleans."
        ),
        ParsecSettingDescriptor(
            id: .noOverlay,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Suppresses the on-screen overlay controls (read when a session view appears).",
            host: .any,
            application: .live,
            invalidCombinationNote: "Never set by the Poor Network Preset: hiding the overlay would remove Disconnect from the session."
        ),
        ParsecSettingDescriptor(
            id: .hideStatusBar,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Hides the iPad status bar during a session.",
            host: .any,
            application: .live,
            invalidCombinationNote: "Owns its own key after a migration split it from cursorScale."
        ),
        ParsecSettingDescriptor(
            id: .rightClickPosition,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Which finger position maps to a right click in touch mode.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .preferredFramesPerSecond,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Preferred present rate (0 = device max/ProMotion).",
            host: .any,
            application: .live,
            invalidCombinationNote: "Untouched by the Poor Network Preset (local refresh is not a network cost)."
        ),
        ParsecSettingDescriptor(
            id: .decoderCompatibility,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Enables a higher-latency compatibility decode path.",
            host: .any,
            application: .reconnect,
            invalidCombinationNote: "Set false by the Poor Network Preset; applies on reconnect and remains overridable."
        ),

        ParsecSettingDescriptor(
            id: .showKeyboardButton,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Shows the on-screen keyboard toggle button.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),

        ParsecSettingDescriptor(
            id: .syncKeyboardLayout,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Fires a layout-switch hotkey at the host when the iPad layout changes.",
            host: .any,
            application: .live,
            invalidCombinationNote: ""
        ),
        ParsecSettingDescriptor(
            id: .layoutSyncHotkey,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Which host hotkey syncKeyboardLayout emits.",
            host: .any,
            application: .live,
            invalidCombinationNote: "Ignored when syncKeyboardLayout is off."
        ),
        ParsecSettingDescriptor(
            id: .ctrlShiftEmulatesCmdSpace,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Bare Ctrl+Shift emits Cmd+Space at a Mac host.",
            host: .macOS,
            application: .live,
            invalidCombinationNote: "Manual opt-in; not auto-gated on host OS."
        ),
        ParsecSettingDescriptor(
            id: .backtickEmulatesCmdSpace,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Bare backtick emits Cmd+Space at a Mac host.",
            host: .macOS,
            application: .live,
            invalidCombinationNote: "Manual opt-in; disables typing a literal backtick to the host while connected."
        ),
        ParsecSettingDescriptor(
            id: .saveSessionSettings,
            kind: .userVisibleControl,
            hasUIControl: true,
            consumer: "Gates persistence of the per-session saved-state keys below.",
            host: .any,
            application: .live,
            invalidCombinationNote: "When off, the saved* keys are not written back."
        ),
        ParsecSettingDescriptor(
            id: .savedZoomEnabled,
            kind: .sessionSavedState,
            hasUIControl: false,
            consumer: "Last zoom-enabled state restored at connect.",
            host: .any,
            application: .restoredOnConnect,
            invalidCombinationNote: "Only persisted when saveSessionSettings is on."
        ),
        ParsecSettingDescriptor(
            id: .savedConstantFps,
            kind: .sessionSavedState,
            hasUIControl: false,
            consumer: "Last constant-FPS state restored at connect.",
            host: .any,
            application: .restoredOnConnect,
            invalidCombinationNote: "Only persisted when saveSessionSettings is on."
        ),
        ParsecSettingDescriptor(
            id: .savedMuted,
            kind: .sessionSavedState,
            hasUIControl: false,
            consumer: "Last audio-muted state restored at connect.",
            host: .any,
            application: .restoredOnConnect,
            invalidCombinationNote: "Only persisted when saveSessionSettings is on."
        ),
        ParsecSettingDescriptor(
            id: .savedDisplayOutput,
            kind: .sessionSavedState,
            hasUIControl: false,
            consumer: "Last chosen host display id restored once the host enumerates displays.",
            host: .any,
            application: .restoredOnConnect,
            invalidCombinationNote: "Only persisted when saveSessionSettings is on; name is the fallback key."
        ),
        ParsecSettingDescriptor(
            id: .savedDisplayName,
            kind: .sessionSavedState,
            hasUIControl: false,
            consumer: "Fallback host display name when the saved id is regenerated between connects.",
            host: .any,
            application: .restoredOnConnect,
            invalidCombinationNote: "Only persisted when saveSessionSettings is on."
        ),
    ]

    /// Number of documented settings in the contract.
    static var coverageCount: Int { descriptors.count }

    /// Number of user-visible controls (subset with a SettingsView control).
    static var userVisibleControlCount: Int {
        descriptors.filter { $0.kind == .userVisibleControl }.count
    }

    static func descriptor(for id: ParsecSettingID) -> ParsecSettingDescriptor? {
        descriptors.first { $0.id == id }
    }

    static func descriptor(forKey key: String) -> ParsecSettingDescriptor? {
        guard let id = ParsecSettingID(rawValue: key) else { return nil }
        return descriptor(for: id)
    }

    /// A setting is applicable to a host when it targets any host or that host.
    static func isApplicable(
        _ key: String,
        to host: ParsecSettingHostApplicability
    ) -> Bool {
        guard let descriptor = descriptor(forKey: key) else { return false }
        return descriptor.host == .any || descriptor.host == host
    }
}
