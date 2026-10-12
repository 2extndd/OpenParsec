
struct ParsecUserDataVideo : Codable {
	var encoderFPS : Int = 0
	var resolutionX : Int = 0
	var resolutionY : Int = 0
	var fullFPS : Bool = false
	var hostOS = 0
	var output = "none"
	var encoderMaxBitrate : Int = 50
}

struct ParsecUserDataVideoConfig : Codable {
	var virtualMicrophone : Int = 0
	var virtualTablet : Int = 0
	var video: [ParsecUserDataVideo] = [
		ParsecUserDataVideo(),
		ParsecUserDataVideo(),
		ParsecUserDataVideo()
	]
}

struct ParsecDisplayConfig : Codable, Hashable {
	var name : String = ""
	var adapterName : String = ""
	var id : String = ""
}

extension ParsecDisplayConfig {
	// Also the persisted savedDisplayName format — keep it byte-identical.
	var label: String { "\(name) \(adapterName)" }

	// Two identical monitors on one GPU report the same name + adapter; the
	// menu showed two indistinguishable rows. Append the host id only then.
	// With exactly two monitors the session menu shows one toggle button:
	// the target is simply the display that isn't currently streamed.
	static func toggleTarget(in configs: [ParsecDisplayConfig], current: String) -> ParsecDisplayConfig? {
		guard configs.count == 2 else { return nil }
		return configs.first { $0.id != current } ?? configs[0]
	}

	func menuLabel(in configs: [ParsecDisplayConfig]) -> String {
		configs.filter { $0.label == label }.count > 1 ? "\(label) (\(id))" : label
	}

	// Saved-display restore. Host ids are not stable (Windows renumbers
	// \\.\DISPLAYn, macOS reassigns ids on hot-plug), so an id match alone can
	// land on a different monitor, and a name match alone is ambiguous for
	// identical monitors. Prefer id+name; else a name that is unique; else
	// nothing (Auto beats guessing). An empty savedName (legacy) matches by id.
	static func restoreMatch(in configs: [ParsecDisplayConfig], savedId: String, savedName: String) -> ParsecDisplayConfig? {
		let named = savedName.isEmpty ? configs : configs.filter { $0.label == savedName }
		if let exact = named.first(where: { !savedId.isEmpty && $0.id == savedId }) { return exact }
		return !savedName.isEmpty && named.count == 1 ? named[0] : nil
	}
}

enum ParsecUserDataType : UInt32 {
	case getVideoConfig = 9
	case getAdapterInfo = 10
	case setVideoConfig = 11
}

// Mac host stream size. A macOS host always streams a display at its full
// pixel size, so smaller sizes come from mac-helper/ParsecLowDisplay: a
// virtual display "Parsec Low" at a fraction of that size which the streamed
// display mirrors. The app drives it with Ctrl+Opt+Cmd+letter hotkeys sent
// through the session. Raw value = the helper's level.
enum MacStreamScale: Int, CaseIterable {
	case native = 0
	case twoThirds = 3
	case half = 2

	static let modifiers = [224, 226, 227].map(RemoteKeyCode.init(rawValue:)) // Ctrl, Opt, Cmd
	static let nextDisplayKey = RemoteKeyCode(rawValue: 15) // L

	var key: RemoteKeyCode { RemoteKeyCode(rawValue: self == .native ? 11 : self == .half ? 13 : 14) } // H, J, K

	// The helper's size: exact fraction, rounded to even.
	func size(native: (width: Int, height: Int)) -> (width: Int, height: Int) {
		let (num, den) = self == .twoThirds ? (2, 3) : self == .half ? (1, 2) : (1, 1)
		func scaled(_ v: Int) -> Int { self == .native ? v : (v * num + den) / (2 * den) * 2 }
		return (scaled(native.width), scaled(native.height))
	}

	func label(native: (width: Int, height: Int)?) -> String {
		let size = native.map { self.size(native: $0) }.map { " \($0.width)×\($0.height)" } ?? ""
		switch self {
		case .native: return "Mac native\(size)"
		case .twoThirds: return "⅔\(size) · sharper, more space"
		case .half: return "½\(size) · Retina 1×, same layout"
		}
	}
}

enum MacLowDisplayPolicy {
	static let displayName = "Parsec Low" // ParsecLowDisplay's virtual display

	static func virtual(in configs: [ParsecDisplayConfig]) -> ParsecDisplayConfig? {
		configs.first { $0.name == displayName }
	}

	// The display the virtual one mirrors drops out of the host's list: the one
	// id of the last list without the virtual display that is missing now.
	static func mirroredSource(native: [ParsecDisplayConfig], current: [ParsecDisplayConfig]) -> String? {
		let missing = native.filter { n in !current.contains { $0.id == n.id } }
		return missing.count == 1 ? missing[0].id : nil
	}

	enum Action: Equatable {
		case none
		case stream(String) // switch the session to this display
		case sendScale      // (re)send the hotkey for the chosen scale
	}

	// What to do with a fresh host display list.
	static func reconcile(configs: [ParsecDisplayConfig], output: String, scale: MacStreamScale, source: String?) -> Action {
		let low = virtual(in: configs)
		if scale != .native {
			guard let low else { return .sendScale }
			return output == low.id ? .none : .stream(low.id)
		}
		if low != nil { return .sendScale } // left on (e.g. set to native in Settings)
		// Back from the virtual display: return to the display it mirrored.
		if !configs.contains(where: { $0.id == output }), let source, configs.contains(where: { $0.id == source }) {
			return .stream(source)
		}
		return .none
	}
}
