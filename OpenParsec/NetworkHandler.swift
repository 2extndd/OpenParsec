import Network
import SwiftUI

class NetworkHandler
{
	public static var clinfo:ClientInfo? = nil
}

enum ParsecAPIEndpoint: String, Equatable, Sendable {
	case authentication
	case hosts
	case currentUser = "current-user"
	case friends
}

enum ParsecAPIFailureCategory: String, Equatable, Sendable {
	case offline
	case sessionExpired = "session-expired"
	case missingResource = "missing-resource"
	case rateLimited = "rate-limited"
	case server
	case rejected
	case malformedResponse = "malformed-response"
}

struct ParsecAPIFailure: Equatable, Sendable {
	let endpoint: ParsecAPIEndpoint
	let category: ParsecAPIFailureCategory
	let statusCode: Int?
	let retryable: Bool
	let requiresSignIn: Bool

	var message: String {
		switch category {
		case .offline:
			return "Network unavailable. Check your connection and try again."
		case .sessionExpired:
			return "Your session expired. Sign in again."
		case .missingResource where endpoint == .hosts:
			return "The requested host is no longer available. Refresh the host list."
		case .missingResource:
			return "The requested resource is no longer available."
		case .rateLimited:
			return "Too many requests. Wait a moment and try again."
		case .server:
			return "The Parsec service is temporarily unavailable. Try again."
		case .rejected where endpoint == .authentication:
			return "Sign-in failed. Check your credentials and try again."
		case .rejected:
			return "The request was rejected. Refresh and try again."
		case .malformedResponse:
			return "Parsec returned an invalid response. Try again."
		}
	}

	var digest: String {
		"endpoint=\(endpoint.rawValue) category=\(category.rawValue) "
			+ "status=\(statusCode.map(String.init) ?? "none") "
			+ "retryable=\(retryable)"
	}
}

struct ParsecRefreshTracker: Equatable, Sendable {
	private(set) var generation: UInt64 = 0
	private(set) var pendingRequests: Int = 0

	var isRefreshing: Bool {
		pendingRequests > 0
	}

	mutating func begin(requestCount: Int) -> UInt64 {
		precondition(requestCount > 0)
		generation &+= 1
		pendingRequests = requestCount
		return generation
	}

	func accepts(generation candidate: UInt64) -> Bool {
		candidate == generation
	}

	@discardableResult
	mutating func finish(generation candidate: UInt64) -> Bool {
		guard accepts(generation: candidate), pendingRequests > 0 else {
			return false
		}
		pendingRequests -= 1
		return true
	}
}

enum ParsecAPIResponseClassifier {
	static func classify(
		endpoint: ParsecAPIEndpoint,
		statusCode: Int?,
		transportFailed: Bool,
		decodedSuccessfully: Bool
	) -> ParsecAPIFailure? {
		guard !transportFailed, let statusCode else {
			return ParsecAPIFailure(
				endpoint: endpoint,
				category: .offline,
				statusCode: nil,
				retryable: true,
				requiresSignIn: false
			)
		}

		if (200..<300).contains(statusCode) {
			guard decodedSuccessfully else {
				return ParsecAPIFailure(
					endpoint: endpoint,
					category: .malformedResponse,
					statusCode: statusCode,
					retryable: true,
					requiresSignIn: false
				)
			}
			return nil
		}

		if statusCode == 401 || statusCode == 403 {
			let expired = endpoint != .authentication
			return ParsecAPIFailure(
				endpoint: endpoint,
				category: expired ? .sessionExpired : .rejected,
				statusCode: statusCode,
				retryable: false,
				requiresSignIn: expired
			)
		}

		if statusCode == 404 {
			return ParsecAPIFailure(
				endpoint: endpoint,
				category: .missingResource,
				statusCode: statusCode,
				retryable: false,
				requiresSignIn: false
			)
		}

		if statusCode == 408 || statusCode == 425 || statusCode == 429 {
			return ParsecAPIFailure(
				endpoint: endpoint,
				category: statusCode == 429 ? .rateLimited : .offline,
				statusCode: statusCode,
				retryable: true,
				requiresSignIn: false
			)
		}

		if (500..<600).contains(statusCode) {
			return ParsecAPIFailure(
				endpoint: endpoint,
				category: .server,
				statusCode: statusCode,
				retryable: true,
				requiresSignIn: false
			)
		}

		return ParsecAPIFailure(
			endpoint: endpoint,
			category: .rejected,
			statusCode: statusCode,
			retryable: false,
			requiresSignIn: false
		)
	}
}

struct ErrorInfo:Decodable
{
	var error: String
//	var codes:Array
}

struct ClientInfo:Decodable
{
	var instance_id: String
	var user_id:Int
	var session_id: String
	var host_peer_id: String
}

struct UserInfo:Decodable
{
	var id:Int
	var name: String
	var warp: Bool
//	var external_id: String
//	var external_provider: String
	var team_id: String
}

struct HostInfo:Decodable
{
	var user: UserInfo
	var peer_id: String
	var game_id: String
	var description: String
	var max_players:Int
	var mode: String
	var name: String
	var event_name: String
	var players:Int
//	var public: Bool
	var guest_access: Bool
	var online: Bool
//	var self: Bool
	var build: String
}

struct HostInfoList:Decodable
{
	var data:Array<HostInfo>?
	var has_more: Bool
}

struct SelfInfoData:Decodable
{
	var id:Int
	var name: String
	var email: String
	var warp: Bool
	var staff: Bool
	var team_id: String
	var is_confirmed: Bool
	var team_is_active: Bool
	var is_saml: Bool
	var is_gateway_enabled: Bool
	var is_relay_enabled: Bool
	var has_tfa: Bool
//	var app_config:Any
	var cohort_channel: String
}

struct SelfInfo:Decodable
{
	var data: SelfInfoData
}

struct FriendInfo:Decodable
{
	var user_id:Int
	var user_name: String
}

struct FriendInfoList:Decodable
{
	var data:Array<FriendInfo>?
	var has_more: Bool
}

// In-app "Connection Test": tells the user on the spot why a session would fail
// (-6013 UDP blocked, -6023/-6024 NAT, VPN routing, Parsec API unreachable).
enum ParsecConnectionTest {
	struct Check: Identifiable {
		let id = UUID()
		let name: String
		let ok: Bool
		let detail: String
		var mapped: String? = nil
	}

	static let magicCookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

	// RFC 5389 Binding Request: type 0x0001, length 0, magic cookie, 12-byte transaction id.
	static func stunBindingRequest(transactionID: [UInt8]) -> Data {
		Data([0x00, 0x01, 0x00, 0x00] + magicCookie + transactionID)
	}

	// Binding Success Response -> XOR-MAPPED-ADDRESS (0x0020), else MAPPED-ADDRESS (0x0001).
	static func parseStunMappedAddress(_ data: Data, transactionID: [UInt8]) -> (ip: String, port: UInt16)? {
		let b = [UInt8](data)
		guard transactionID.count == 12, b.count >= 20, b[0] == 0x01, b[1] == 0x01,
			Array(b[4..<8]) == magicCookie, Array(b[8..<20]) == transactionID else { return nil }
		var plain: (String, UInt16)?
		var i = 20
		while i + 4 <= b.count {
			let type = UInt16(b[i]) << 8 | UInt16(b[i + 1])
			let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
			let v = i + 4
			guard v + len <= b.count else { break }
			if (type == 0x0020 || type == 0x0001), len >= 8 {
				let xor = type == 0x0020
				let family = b[v + 1]
				let addrLen = family == 0x01 ? 4 : family == 0x02 ? 16 : 0
				if addrLen > 0, len >= 4 + addrLen {
					let mask = xor ? magicCookie + transactionID : [UInt8](repeating: 0, count: 16)
					let port = (UInt16(b[v + 2]) << 8 | UInt16(b[v + 3])) ^ (xor ? 0x2112 : 0)
					let raw = Data((0..<addrLen).map { b[v + 4 + $0] ^ mask[$0] })
					let ip = addrLen == 4 ? IPv4Address(raw).map { "\($0)" } : IPv6Address(raw).map { "\($0)" }
					if let ip = ip {
						if xor { return (ip, port) }
						plain = (ip, port)
					}
				}
			}
			i = v + (len + 3) / 4 * 4
		}
		return plain.map { (ip: $0.0, port: $0.1) }
	}

	// One plain-language conclusion; first matching cause wins.
	// mapped: IPv4 "ip:port" seen by each STUN server that answered.
	static func verdict(online: Bool, vpnPrimary: Bool, parsecReachable: Bool, mapped: [String], ipv6UDP: Bool) -> String {
		let symmetric = Set(mapped).count > 1
		if !online { return "No network connection." }
		if mapped.isEmpty && !ipv6UDP {
			return vpnPrimary
				? "UDP is blocked (expect -6013): the VPN is capturing UDP. Turn the VPN off or exclude OpenParsec from it."
				: "UDP is blocked (expect -6013): this network blocks UDP. Try another Wi-Fi or cellular."
		}
		if !parsecReachable {
			return "Parsec servers unreachable: login/handshake will fail. Enable the VPN only for *.parsec.app and *.parsecgaming.com."
		}
		if vpnPrimary {
			return "The VPN is the primary route, so the stream goes through it and may fail (-6013/-6023). Route only *.parsec.app and *.parsecgaming.com through the VPN."
		}
		if mapped.isEmpty { return "IPv4 UDP is blocked; only IPv6 works. Connecting works only if the host has IPv6." }
		if symmetric && !ipv6UDP {
			return "Symmetric NAT on IPv4 and no IPv6: P2P will likely fail (-6023/-6024). Use a network with IPv6 or forward a UDP port on the host."
		}
		if symmetric { return "Symmetric NAT on IPv4, but IPv6 works: connect over IPv6 (the host has public IPv6)." }
		if !ipv6UDP { return "No global IPv6. IPv4 NAT looks fine, P2P should work; if -6023 appears, use a network with IPv6." }
		return "All good: UDP, NAT and IPv6 OK. If connecting still fails, check the host."
	}

	static func run(completion: @escaping ([Check], String) -> Void) {
		let q = DispatchQueue(label: "openparsec.conn-test")
		let monitor = NWPathMonitor()
		monitor.pathUpdateHandler = { path in
			monitor.pathUpdateHandler = nil
			monitor.cancel()
			let primary = path.availableInterfaces.first
			let vpn = NetworkPathObserver.isVPN(primary?.name ?? "")
			let kind = primary.map { "\($0.type)" } ?? "none"
			var checks = [Check(name: "Network", ok: path.status == .satisfied && !vpn,
				detail: "\(path.status), \(kind) \(primary?.name ?? "-")\(vpn ? ", VPN is primary route" : ""), IPv6 \(path.supportsIPv6 ? "yes" : "no")")]
			note(checks[0])

			var slots = [Check?](repeating: nil, count: 6) // 5 = optional IPv4 fallback
			let group = DispatchGroup()
			func probe(_ i: Int, _ start: (@escaping (Check) -> Void) -> Void) {
				group.enter()
				start { c in q.async { note(c); slots[i] = c; group.leave() } }
			}
			probe(0) { https("https://kessel-api.parsec.app/", $0) }
			probe(1) { https("https://kessel-ws.parsecgaming.com/", $0) }
			// All IPv4 probes share one local port: NAT type is only visible when the
			// same socket is mapped differently per destination. Servers checked live
			// from China (2026-10): stun.qq.com and stun.miwifi.com did not answer directly.
			let local = NWEndpoint.Port(rawValue: UInt16.random(in: 50000...60000))!
			// Sequential: a bound port can't be shared by two live flows (EADDRINUSE).
			probe(2) { done in
				stun("stun.chat.bilibili.com", 3478, local: local) { c in
					probe(3) { stun("stun.hitv.com", 3478, local: local, $0) }
					done(c)
				}
			}
			if path.supportsIPv6 {
				probe(4) { stun("stun.cloudflare.com", 3478, local: nil, $0) }
			} else {
				slots[4] = Check(name: "STUN IPv6", ok: false, detail: "No IPv6 on this network")
			}

			func finish() {
				checks += slots.compactMap { $0 }
				let mapped = [slots[2], slots[3], slots[5]].compactMap { $0?.mapped }
				let result = verdict(online: path.status == .satisfied, vpnPrimary: vpn,
					parsecReachable: slots[0]?.ok == true || slots[1]?.ok == true,
					mapped: mapped, ipv6UDP: slots[4]?.ok == true)
				Diagnostics.note("conn-test verdict: \(result)")
				DispatchQueue.main.async { completion(checks, result) }
			}
			group.notify(queue: q) {
				// Need two mappings to judge NAT type; fall back to Cloudflare if a China server failed.
				guard slots[2...3].filter({ $0?.ok == true }).count < 2 else { return finish() }
				probe(5) { stun("stun.cloudflare.com", 3478, local: local, $0) }
				group.notify(queue: q, execute: finish)
			}
		}
		monitor.start(queue: q)
	}

	private static func note(_ c: Check) {
		Diagnostics.note("conn-test \(c.name) ok=\(c.ok) \(c.detail)")
	}

	private static func https(_ url: String, _ done: @escaping (Check) -> Void) {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 4
		config.timeoutIntervalForResource = 4
		let session = URLSession(configuration: config)
		let start = Date()
		let host = URL(string: url)!.host!
		session.dataTask(with: URL(string: url)!) { _, response, error in
			session.finishTasksAndInvalidate()
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			if let http = response as? HTTPURLResponse {
				done(Check(name: host, ok: true, detail: "HTTP \(http.statusCode), \(ms) ms"))
			} else {
				done(Check(name: host, ok: false, detail: error?.localizedDescription ?? "no response"))
			}
		}.resume()
	}

	// local == nil means IPv6 probe on an ephemeral port; otherwise IPv4 bound to `local`.
	private static func stun(_ host: String, _ port: UInt16, local: NWEndpoint.Port?, _ done: @escaping (Check) -> Void) {
		let v6 = local == nil
		let name = "STUN \(v6 ? "IPv6" : "IPv4") \(host)"
		let params = NWParameters.udp
		(params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = v6 ? .v6 : .v4
		if let local = local {
			params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: local)
			params.allowLocalEndpointReuse = true
		}
		let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
		let q = DispatchQueue(label: "openparsec.conn-test.stun")
		let txid = (0..<12).map { _ in UInt8.random(in: 0...255) }
		let request = stunBindingRequest(transactionID: txid)
		var result: Check?
		let start = Date()
		// Report only once .cancelled, i.e. the local port is released for the next probe.
		func finish(_ ok: Bool, _ detail: String, _ mapped: String? = nil) {
			guard result == nil else { return }
			result = Check(name: name, ok: ok, detail: detail, mapped: mapped)
			conn.cancel()
		}
		func send() { conn.send(content: request, completion: .contentProcessed { _ in }) }
		conn.stateUpdateHandler = { state in
			switch state {
			case .ready:
				send()
				q.asyncAfter(deadline: .now() + 1.5) { if result == nil { send() } } // one retransmit for UDP loss
				conn.receiveMessage { data, _, _, error in
					let ms = Int(Date().timeIntervalSince(start) * 1000)
					if let data = data, let m = parseStunMappedAddress(data, transactionID: txid) {
						let mapped = v6 ? "[\(m.ip)]:\(m.port)" : "\(m.ip):\(m.port)"
						finish(true, "mapped \(mapped), \(ms) ms", mapped)
					} else {
						finish(false, error.map { "\($0)" } ?? "bad STUN reply")
					}
				}
			case .failed(let error): finish(false, "\(error)")
			case .waiting(let error): finish(false, "\(error)")
			case .cancelled: done(result!)
			default: break
			}
		}
		q.asyncAfter(deadline: .now() + 4) { finish(false, "timeout (UDP blocked?)") }
		conn.start(queue: q)
	}
}

struct ConnectionTestView: View {
	@State private var running = false
	@State private var checks: [ParsecConnectionTest.Check] = []
	@State private var verdict = ""

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Button(running ? "Testing…" : "Run Connection Test") {
					running = true
					checks = []
					verdict = ""
					ParsecConnectionTest.run { checks = $0; verdict = $1; running = false }
				}
				.disabled(running)
				.foregroundColor(Color("AccentColor"))
				ForEach(checks) { c in
					HStack(alignment: .top) {
						Text(c.ok ? "✓" : "✗").foregroundColor(c.ok ? .green : .red)
						VStack(alignment: .leading) {
							Text(c.name).foregroundColor(Color("Foreground"))
							Text(c.detail).font(.caption).foregroundColor(.gray)
						}
					}
				}
				if !verdict.isEmpty {
					Text(verdict)
						.foregroundColor(Color("Foreground"))
						.padding()
						.background(Rectangle().fill(Color("BackgroundGray")))
						.cornerRadius(8)
				}
			}
			.padding()
		}
	}
}
