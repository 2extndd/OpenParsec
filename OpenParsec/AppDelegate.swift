import UIKit
import Network
import Darwin

// Lightweight crash reporter. Writes the last uncaught exception / fatal
// signal (with a backtrace) to Documents/last_crash.log. On the next launch
// the log is copied to the system pasteboard (so it can be pasted straight
// into a chat, or synced to a Mac via Universal Clipboard) and left in the
// app's Documents folder, which is exposed in the Files app via
// UIFileSharingEnabled. Zero infrastructure required.
enum CrashReporter {
	static var logURL: URL {
		let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		return docs.appendingPathComponent("last_crash.log")
	}

	// ---- Async-signal-safe state, all pre-allocated in install() ----
	// The signal handler must never call malloc, Foundation, or Swift String:
	// if the crashing thread already holds the malloc lock (the common case for
	// SIGSEGV/SIGABRT), any allocation inside the handler deadlocks and the log
	// never gets written — exactly the failure that made crashes undiagnosable.
	// So everything the handler touches is allocated up front here.
	//
	// All of it is `static let` (immutable): reading a `static var` from the
	// handler runs Swift's exclusivity check (swift_beginAccess), which can
	// allocate — on a corrupt heap that re-crashed the handler (SIGTRAP) and
	// overwrote the real signal in last_crash.log. install() touches each one
	// so their one-time initialisation never happens inside the handler.
	private static let logPathC: UnsafeMutablePointer<CChar> = strdup(logURL.path)
	private static let headerPrefixC: UnsafeMutablePointer<CChar> = strdup("=== OpenParsec fatal signal ")
	private static let headerSuffixC: UnsafeMutablePointer<CChar> = strdup(" ===\nBacktrace:\n")
	private static let backtraceCapacity: Int32 = 128
	private static let backtraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
	// Set to 1 by the NSException handler so a following SIGABRT (from the
	// uncaught-exception abort) appends instead of clobbering the richer log.
	private static let exceptionRecorded: UnsafeMutablePointer<sig_atomic_t> = {
		let flag = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)
		flag.pointee = 0
		return flag
	}()

	// Rich recorder for the NSException path ONLY. Runs in normal context
	// (not a signal trampoline), so Foundation/allocation is safe here.
	static func record(_ header: String) {
		let stamp = ISO8601DateFormatter().string(from: Date())
		var text = "=== OpenParsec crash @ \(stamp) ===\n"
		text += header + "\n\nBacktrace:\n"
		text += Thread.callStackSymbols.joined(separator: "\n")
		text += "\n"
		try? text.write(to: logURL, atomically: true, encoding: .utf8)
		exceptionRecorded.pointee = 1
	}

	// Async-signal-safe write of a decimal Int32 using a stack buffer only —
	// no heap, so it is safe to call from the signal handler.
	private static func writeInt(_ fd: Int32, _ value: Int32) {
		withUnsafeTemporaryAllocation(of: CChar.self, capacity: 12) { p in
			var i = 12
			var n = value
			let negative = n < 0
			if negative { n = -n }
			if n == 0 { i -= 1; p[i] = CChar(48) } // '0'
			while n > 0 { i -= 1; p[i] = CChar(48 + Int(n % 10)); n /= 10 }
			if negative { i -= 1; p[i] = CChar(45) } // '-'
			_ = write(fd, p.baseAddress! + i, 12 - i)
		}
	}

	// THE SIGNAL HANDLER. Async-signal-safe primitives only: open, write,
	// backtrace, backtrace_symbols_fd (writes straight to the fd, no malloc),
	// close, signal, raise.
	private static func handleSignal(_ s: Int32) {
		// First: a fault inside this handler must kill the app, not re-enter
		// it and truncate the log. Separate calls (an array would allocate).
		signal(SIGABRT, SIG_DFL)
		signal(SIGSEGV, SIG_DFL)
		signal(SIGBUS, SIG_DFL)
		signal(SIGILL, SIG_DFL)
		signal(SIGFPE, SIG_DFL)
		signal(SIGTRAP, SIG_DFL)
		// Append (don't truncate) if the exception handler already wrote a
		// richer log before abort()ing into this signal.
		let flags = exceptionRecorded.pointee != 0
			? (O_WRONLY | O_CREAT | O_APPEND)
			: (O_WRONLY | O_CREAT | O_TRUNC)
		let fd = open(logPathC, flags, 0o644)
		if fd >= 0 {
			_ = write(fd, headerPrefixC, strlen(headerPrefixC))
			writeInt(fd, s)
			_ = write(fd, headerSuffixC, strlen(headerSuffixC))
			let frames = backtrace(backtraceBuffer, backtraceCapacity)
			backtrace_symbols_fd(backtraceBuffer, frames, fd)
			_ = fsync(fd)
			close(fd)
		}
		raise(s)
	}

	static func install() {
		// Initialise everything the signal handler touches now, and load
		// backtrace()'s machinery once so the handler never triggers dyld work.
		_ = (logPathC, headerPrefixC, headerSuffixC, exceptionRecorded)
		_ = backtrace(backtraceBuffer, 1)

		NSSetUncaughtExceptionHandler { exception in
			CrashReporter.record(
				"Uncaught NSException: \(exception.name.rawValue)\n" +
				"Reason: \(exception.reason ?? "(nil)")\n" +
				"User stack:\n" + exception.callStackSymbols.joined(separator: "\n")
			)
		}
		for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
			signal(sig) { s in
				CrashReporter.handleSignal(s)
			}
		}
	}

	// Non-destructive read so a Settings "Copy Last Crash Log" action can
	// retrieve it at any time. The file is overwritten on the next crash and
	// can be cleared explicitly via clear().
	static var hasLog: Bool {
		FileManager.default.fileExists(atPath: logURL.path)
	}

	static func peek() -> String? {
		guard let text = try? String(contentsOf: logURL, encoding: .utf8), !text.isEmpty else { return nil }
		return text
	}

	static func clear() {
		try? FileManager.default.removeItem(at: logURL)
	}
}

// Lightweight append-only diagnostics channel, sibling to CrashReporter.
// Used for empirical discovery that has no local console (e.g. the host-OS
// int encoding in S04, or netProtocol/mediaContainer in S08). Entries persist
// to Documents/diagnostics.log and can be copied out via Settings →
// "Copy Diagnostics" or pulled from the Files app. Called only from normal
// (non-signal) contexts, so Foundation use is fine here.
enum Diagnostics {
	static var logURL: URL {
		let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		return docs.appendingPathComponent("diagnostics.log")
	}

	// Called from input, SDK log and poll threads: callers only enqueue (no file
	// I/O on the click/chord hot paths); one serial queue writes, in order.
	private static let queue = DispatchQueue(label: "openparsec.diagnostics", qos: .utility)
	// Created once (~60 µs each); only used on `queue`.
	private static let formatter = ISO8601DateFormatter()
	// Collapse bursts of identical SDK lines (72× nat_read_packet in 2 s).
	private static var lastSDKLine: String?
	private static var repeats = 0

	static func note(_ line: String) {
		let now = Date()
		queue.async { write(line, at: now) }
	}

	private static func write(_ line: String, at date: Date) {
		if line.hasPrefix("sdk-log "), line == lastSDKLine {
			repeats += 1
			return
		}
		if repeats > 0 {
			let n = repeats
			repeats = 0
			write("sdk-log (previous line repeated \(n)×)", at: date)
		}
		lastSDKLine = line.hasPrefix("sdk-log ") ? line : nil
		let stamp = formatter.string(from: date)
		let entry = "[\(stamp)] \(line)\n"
		print("[OpenParsec][diag] \(line)")
		guard let data = entry.data(using: .utf8) else { return }
		if let handle = try? FileHandle(forWritingTo: logURL) {
			// Throwing APIs: the legacy seekToEndOfFile()/write(_:) raise an
			// ObjC exception (uncatchable crash) on errors such as a full disk.
			let size = (try? handle.seekToEnd()) ?? 0
			try? handle.write(contentsOf: data)
			try? handle.close()
			// Long background-audio sessions log for hours: cap while running.
			if size > 4_000_000 { trimIfNeeded(maxBytes: 4_000_000) }
		} else {
			// File doesn't exist yet — create it with this first entry.
			try? data.write(to: logURL, options: .atomic)
		}
	}

	// SDK log lines make the file grow; keep the newest ~1 MB across launches.
	static func trimIfNeeded(maxBytes: Int = 2_000_000) {
		guard let data = try? Data(contentsOf: logURL), data.count > maxBytes else { return }
		try? data.suffix(maxBytes / 2).write(to: logURL, options: .atomic)
	}

	static var hasLog: Bool {
		FileManager.default.fileExists(atPath: logURL.path)
	}

	static func peek() -> String? {
		queue.sync {}  // readers see every line noted before the call
		// Lossy decode: a trim can cut a multi-byte character in half.
		guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return nil }
		return String(decoding: data, as: UTF8.self)
	}


	static func clear() {
		try? FileManager.default.removeItem(at: logURL)
	}
}

// Records network path changes and exposes a digest for connect diagnostics,
// so NAT/UDP failures (-6013, -6023) can be correlated with Wi-Fi state.
enum NetworkPathObserver {
	private static let lock = NSLock()
	private static var current = "net=unknown"
	private static let monitor: NWPathMonitor = {
		let monitor = NWPathMonitor()
		monitor.pathUpdateHandler = { path in
			let kind = path.usesInterfaceType(.wifi) ? "wifi"
				: path.usesInterfaceType(.wiredEthernet) ? "ethernet"
				: path.usesInterfaceType(.cellular) ? "cellular" : "other"
			// iOS always has idle utun interfaces, so only a tunnel as the
			// preferred interface means traffic goes through a VPN (which
			// often drops UDP: -6013).
			let primary = path.availableInterfaces.first?.name ?? "none"
			let vpn = isVPN(primary)
			let digest = "net=\(path.status) if=\(kind) primary=\(primary) vpn=\(vpn) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
			lock.lock()
			let changed = current != digest
			current = digest
			lock.unlock()
			if changed { Diagnostics.note("network-path \(digest)") }
		}
		monitor.start(queue: DispatchQueue(label: "openparsec.network-path"))
		return monitor
	}()

	static func start() { _ = monitor }

	static func isVPN(_ interfaceName: String) -> Bool {
		["utun", "ipsec", "ppp", "tap", "tun"].contains(where: interfaceName.hasPrefix)
	}

	static var digest: String {
		lock.lock()
		defer { lock.unlock() }
		return current
	}
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate
{
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey: Any]?) -> Bool
	{
		// Install the crash reporter as early as possible so it catches
		// failures during the rest of launch too.
		CrashReporter.install()
		Diagnostics.trimIfNeeded()
		SettingsHandler.endPoorNetworkPreset() // killed mid-session: the user's own settings again
		// Marks every process start, so a silent end (force-quit, jetsam) shows
		// as a gap followed by this line instead of looking like a hang.
		let info = Bundle.main.infoDictionary
		Diagnostics.note("app-launch version=\(info?["CFBundleShortVersionString"] ?? "?") build=\(info?["CFBundleVersion"] ?? "?") crashLog=\(CrashReporter.peek() != nil)")
		NetworkPathObserver.start()
		// Q1: repair the hideStatusBar / cursorScale shared-key corruption
		// before any UI reads these settings.
		SettingsHandler.migrateLegacyStatusBarKeyIfNeeded()
		SettingsHandler.migratePointerPresentationModeIfNeeded()
		SettingsHandler.migrateWindowsKeyboardRemapIfNeeded()
		SettingsHandler.migrateHostShortcutToolbarIfNeeded()
		SettingsHandler.migrateLayoutSyncHotkeyIfNeeded()
		if let crash = CrashReporter.peek() {
			// Make the previous crash trivially retrievable: copy to the
			// pasteboard (syncs to a Mac on the same Apple ID via Universal
			// Clipboard) and print it for any attached console. The file is
			// kept (not consumed) so the Settings "Copy Last Crash Log" row
			// can re-surface it later.
			// Only once per crash: later launches must not keep overwriting the
			// user's clipboard (Universal Clipboard pushes it to the Mac too).
			let flag = "crashLogCopiedFor"
			if UserDefaults.standard.string(forKey: flag) != crash {
				UIPasteboard.general.string = crash
				UserDefaults.standard.set(crash, forKey: flag)
			}
			print("[OpenParsec] Recovered crash log from previous run:\n\(crash)")
		}

		// Override point for customization after application launch.
		UTMViewControllerPatches.patchAll()
		return true
	}

	func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration
	{
		// Called when a new scene session is being created.
		// Use this method to select a configuration to create the new scene with.
		return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
	}

	func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>)
	{
		// Called when the user discards a scene session.
		// If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
		// Use this method to release any resources that were specific to the discarded scenes, as they will not return.
	}

	func applicationWillTerminate(_ application: UIApplication)
	{
		// Close the host session now; otherwise the host keeps a ghost
		// session (and its bandwidth) for ~60 s until it times out.
		Diagnostics.note("app-terminate")
		CParsec.disconnect(reason: .user)
		CParsec.destroy()
	}
}
