import Foundation
import SwiftUI

var appScheme: ColorScheme = .dark

enum OpenParsecRuntime {
	static var isUITesting: Bool {
#if DEBUG && targetEnvironment(simulator)
		return ProcessInfo.processInfo.arguments.contains("--ui-testing")
#else
		return false
#endif
	}

	static var disablesPiP: Bool {
#if targetEnvironment(simulator)
		return isUITesting
			&& ProcessInfo.processInfo.arguments.contains("--disable-pip")
#else
		// Production background recovery must not surface a visible PiP window.
		return true
#endif
	}

	static var uiTestAPIFailure: String? {
		guard isUITesting else { return nil }
		let prefix = "--api-failure="
		guard let argument = ProcessInfo.processInfo.arguments.first(
			where: { $0.hasPrefix(prefix) }
		) else { return nil }
		return String(argument.dropFirst(prefix.count))
	}

	static var backgroundGracePeriod: TimeInterval {
		guard isUITesting else { return 20 }
		return timeIntervalArgument("--background-grace=") ?? 20
	}

	static var backgroundReconnectDelay: TimeInterval {
		guard isUITesting else { return 0.5 }
		return timeIntervalArgument("--background-reconnect-delay=") ?? 0.5
	}

	static var mediaSoftDeadline: TimeInterval {
		guard isUITesting else { return 3 }
		return timeIntervalArgument("--media-soft-deadline=") ?? 3
	}

	static var mediaHardDeadline: TimeInterval {
		guard isUITesting else { return 10 }
		return timeIntervalArgument("--media-hard-deadline=") ?? 10
	}

	static var holdsTestKeyboardKey: Bool {
		isUITesting && ProcessInfo.processInfo.arguments.contains("--hold-test-key")
	}

	static var executesTestMacShortcut: Bool {
		isUITesting && ProcessInfo.processInfo.arguments.contains("--execute-test-mac-shortcut")
	}

	static var executesTestWindowsShortcut: Bool {
		isUITesting && ProcessInfo.processInfo.arguments.contains("--execute-test-windows-shortcut")
	}

	static var executesTestGamepadInput: Bool {
		isUITesting && ProcessInfo.processInfo.arguments.contains("--execute-test-gamepad-input")
	}

	static var windowsKeyboardModeOverride: WindowsKeyboardMode? {
		guard isUITesting else { return nil }
		if ProcessInfo.processInfo.arguments.contains("--windows-mode=command-as-control") {
			return .commandAsControl
		}
		if ProcessInfo.processInfo.arguments.contains("--windows-mode=direct") {
			return .direct
		}
		return nil
	}

	static var macShortcutButtonsOverride: Bool? {
		guard isUITesting else { return nil }
		if ProcessInfo.processInfo.arguments.contains("--mac-shortcuts=true") {
			return true
		}
		if ProcessInfo.processInfo.arguments.contains("--mac-shortcuts=false") {
			return false
		}
		return nil
	}

	static var pointerPresentationModeOverride: PointerPresentationMode? {
		guard isUITesting,
		      let argument = ProcessInfo.processInfo.arguments.first(where: {
		          $0.hasPrefix("--pointer-mode=")
		      }) else { return nil }
		switch String(argument.dropFirst("--pointer-mode=".count)) {
		case "native":
			return .native
		case "captured":
			return .captured
		default:
			return nil
		}
	}

	private static func timeIntervalArgument(_ prefix: String) -> TimeInterval? {
		guard let argument = ProcessInfo.processInfo.arguments.first(where: {
			$0.hasPrefix(prefix)
		}) else { return nil }
		return TimeInterval(String(argument.dropFirst(prefix.count)))
	}
}

struct GLBData
{
	let SessionKeyChainKey = "OPStoredAuthData"
}

class GLBDataModel
{
	static let shared = GLBData()
}

extension String
{
	static func fromBuffer(_ ptr: UnsafeMutablePointer<CChar>, length len:Int) -> String
	{
		// convert C char bytes using the UTF8 encoding
		// Host-supplied bytes: invalid UTF-8 must not crash (repairs instead).
		let bytes = UnsafeRawBufferPointer(start: ptr, count: Swift.max(0, len))
		return String(decoding: bytes, as: UTF8.self)
	}
}

class CursorPositionHelper {
	private static func clamp<T: Comparable>(_ value: T, minValue: T, maxValue: T) -> T {
		return min(max(value, minValue), maxValue)
	}

	static func toHost(_ xp: Int, _ yp : Int) -> (Int, Int) {
		let xh = CParsec.hostWidth
		let yh = CParsec.hostHeight
		let xc = CParsec.clientWidth
		let yc = CParsec.clientHeight
		
		let tc = yc / xc
		let th = yh / xh
		
		var xa: Float
		var ya: Float
		if th < tc {
			xa = Float(xp) * xh / xc
			ya = (Float(yp) - 0.5 * (yc - xc*th)) * xh / xc
		} else {
			ya = Float(yp) * yh / yc
			xa = (Float(xp) - 0.5 * (xc - yc/th)) * yh / yc
		}
		
		return (Int(clamp(xa, minValue: 0, maxValue: CParsec.hostWidth)), Int(clamp(ya,minValue: 0,maxValue: CParsec.hostHeight)))
	}
	
	static func toClient(_ xa: Int, _ ya : Int) -> (Int, Int) {
		let xh = CParsec.hostWidth
		let yh = CParsec.hostHeight
		let xc = CParsec.clientWidth
		let yc = CParsec.clientHeight
		
		let tc = yc / xc
		let th = yh / xh
		
		var xp: Float
		var yp: Float
		if th < tc {
			xp = Float(xa) * xc / xh
			yp = Float(ya) * xc / xh + 0.5 * (yc - xc*th)
		} else {
			yp = Float(ya) * yc / yh
			xp = Float(xa) * yc / yh + 0.5 * (xc - yc/th)
		}
		
		return (Int(clamp(xp,minValue: 0, maxValue: CParsec.clientWidth)), Int(clamp(yp, minValue: 0, maxValue: CParsec.clientHeight)))
	}
}

class SharedModel: ObservableObject {
	@Published var resolutionX = 0
	@Published var resolutionY = 0
	@Published var bitrate = 0
	@Published var constantFps = false
	@Published var output = "none"
	// Output the host reports it is streaming (case-11 echo); "none" until known.
	@Published var hostOutput = "none"
	@Published var displayConfigs: [ParsecDisplayConfig] = []
	// Host OS as reported in the case-11 video config. -1 = unknown / not yet
	// received. The Int→OS encoding is empirical (see HostOS.from); this raw
	// value is surfaced for discovery logging and feature gating.
	@Published var hostOS: Int = -1

}

class DataManager {
	static let model = SharedModel()
}
