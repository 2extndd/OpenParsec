
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
