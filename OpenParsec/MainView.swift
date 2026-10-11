import SwiftUI

struct MainView: View
{
	private static let uiTestPeerID = "openparsec-ui-test-peer"

	var controller:ContentView?

	@State private var page:Page = .hosts

	// Host page vars
	@State var hostCountStr: String = "0 hosts"
	@State var refreshTime: String = "Last refreshed at 1/1/1970 12:00 AM"

	@State var hosts:Array<IdentifiableHostInfo> = []

	// Friend page vars
	@State var friendCountStr: String = "0 friends"

	@State var userInfo:IdentifiableUserInfo? = nil
	@State var friends:Array<IdentifiableUserInfo> = []

	// Global vars
	@State var showBaseAlert: Bool = false
	@State var baseAlertText: String = ""
	@State private var returnToLoginAfterAlert = false
	@State private var refreshTracker = ParsecRefreshTracker()

	@State var showLogoutAlert: Bool = false

	@State var isConnecting: Bool = false
	@State var connectingToName: String = ""
	@State private var lastConnectedPeerName: String = ""
	@State var pollTimer: Timer?

	@State var isRefreshing: Bool = false

	@State var inSettings: Bool = false

	var busy: Bool
	{
		isConnecting || isRefreshing || inSettings
	}

	init(_ controller:ContentView?)
	{
		self.controller = controller
	}

	var body: some View
	{
		ZStack()
		{
			// Background
			Rectangle()
				.fill(Color("BackgroundTab"))
				.edgesIgnoringSafeArea(.all)
			Rectangle()
				.fill(Color("BackgroundGray"))
				.padding(.vertical, 52)

			// Main controls
			VStack()
			{
				// Navigation controls
				HStack()
				{
					Button(action:{ showLogoutAlert = true }, label:{ Image("SymbolExit").scaleEffect(x:-1) })
						.padding()
						.alert(isPresented:$showLogoutAlert)
						{
							Alert(title: Text("Are you sure you want to logout?"), primaryButton:.destructive(Text("Logout"), action:logout), secondaryButton:.cancel(Text("Cancel")))
						}
//					Button(action: {
//						if let c = controller
//						{
//							c.setView(.test)
//
//						}
//						
//					}, label: {
//						Text("Show TestView")
//					})
					
					Spacer()
					HStack()
					{
						if page == .hosts
						{
							// Probably not the best solution for equal spacing, but I don't know how to do math properly in SwiftUI. Please send me an issue if you have a better solution.
							Image(systemName:"arrow.clockwise")
								.padding(4)
								.opacity(0)

							Text(hostCountStr)
								.multilineTextAlignment(.center)
								.foregroundColor(Color("Foreground"))
								.font(.system(size:20, weight:.medium))
							Button(action:refreshHosts, label:{ Image(systemName:"arrow.clockwise") })
								.padding(4)
						}
						else if page == .friends
						{
							Text(friendCountStr)
								.multilineTextAlignment(.center)
								.foregroundColor(Color("Foreground"))
								.font(.system(size:20, weight:.medium))
						}
					}
					Spacer()
					Button(action:{ inSettings = true }, label:{ Image(systemName:"gear") })
						.padding()
				}
				.foregroundColor(Color("AccentColor"))
				.background(Color("BackgroundTab")
					.frame(height:52)
					.shadow(color:Color("Shading"), radius:4, y:6)
					.mask(Rectangle().frame(height:80).offset(y:50))
				)
				.zIndex(1)

				ZStack()
				{
					// Hosts page
					ScrollView(.vertical)
					{
						VStack()
						{
							Text(refreshTime)
								.multilineTextAlignment(.center)
								.opacity(0.5)
							ForEach(hosts)
							{ i in
								ZStack()
								{
									VStack()
									{
										URLImage(url: URL(string:"https://parsecusercontent.com/cors-resize-image/w=64,h=64,fit=crop,background=white,q=90,f=jpeg/avatars/\(String(i.user.id))/avatar"),
												output:
												{
													$0
														.resizable()
														.aspectRatio(contentMode:.fit)
														.frame(width:64, height:64)
														.cornerRadius(8)
												},
												placeholder:
												{
													Image("IconTransparent")
														.resizable()
														.aspectRatio(contentMode:.fit)
														.frame(width:64, height:64)
														.background(Rectangle().fill(Color("BackgroundPrompt")))
														.cornerRadius(8)
												})
										Text(i.hostname)
											.font(.system(size:20, weight:.medium))
											.multilineTextAlignment(.center)
										Text("\(i.user.name)#\(String(i.user.id))")
											.font(.system(size:16, weight:.medium))
											.multilineTextAlignment(.center)
											.opacity(0.5)
										Button(action:{ connectTo(i) })
										{
											ZStack()
											{
												Rectangle()
													.fill(Color("AccentColor"))
													.cornerRadius(8)
												Text("Connect")
													.foregroundColor(.white)
													.padding(8)
											}
											.frame(maxWidth:100)
										}
										.accessibilityIdentifier(i.id == Self.uiTestPeerID ? "openparsec.fake-host.connect" : "openparsec.host.\(i.id).connect")
									}

									if i.connections > 0
									{
										VStack()
										{
											HStack()
											{
												Image(systemName:"person.fill")
												Text(String(i.connections))
													.font(.system(size:16, weight:.medium))
												Spacer()
											}
											Spacer()
										}
									}
								}
								.padding()
								.frame(maxWidth:400)
								.background(Rectangle().fill(Color("BackgroundCard")))
								.cornerRadius(8)
							}
						}
						.padding()
					}
					.zIndex(page == .hosts ? 0 : -1)
					.disabled(page != .hosts)
					.opacity(page == .hosts ? 1 : 0)

					// Friends page
					ScrollView(.vertical)
					{
						VStack()
						{
							if let user = userInfo
							{
								Text("You")
									.multilineTextAlignment(.center)
									.opacity(0.5)
								HStack()
								{
									URLImage(url: URL(string:"https://parsecusercontent.com/cors-resize-image/w=48,h=48,fit=crop,background=white,q=90,f=jpeg/avatars/\(String(user.id))/avatar"),
										output:
										{
											$0
												.resizable()
												.aspectRatio(contentMode:.fit)
												.frame(width:48, height:48)
												.cornerRadius(6)
										},
										placeholder:
										{
											Image("IconTransparent")
												.resizable()
												.aspectRatio(contentMode:.fit)
												.frame(width:48, height:48)
												.background(Rectangle().fill(Color("BackgroundPrompt")))
												.cornerRadius(6)
										})
									Text("\(user.username)#\(String(user.id))")
										.font(.system(size:16, weight:.medium))
										.multilineTextAlignment(.center)
									Spacer()
								}
								.padding(8)
								.background(Color("BackgroundCard"))
								.cornerRadius(12)
							}
							if friends.count > 0
							{
								Text("Friends")
									.multilineTextAlignment(.center)
									.opacity(0.5)
								ForEach(friends)
								{ i in
									HStack()
									{
										URLImage(url: URL(string:"https://parsecusercontent.com/cors-resize-image/w=48,h=48,fit=crop,background=white,q=90,f=jpeg/avatars/\(String(i.id))/avatar"),
											output:
											{
												$0
													.resizable()
													.aspectRatio(contentMode:.fit)
													.frame(width:48, height:48)
													.cornerRadius(6)
											},
											placeholder:
											{
												Image("IconTransparent")
													.resizable()
													.aspectRatio(contentMode:.fit)
													.frame(width:48, height:48)
													.background(Rectangle().fill(Color("BackgroundPrompt")))
													.cornerRadius(6)
											})
										Text("\(i.username)#\(String(i.id))")
											.font(.system(size:16, weight:.medium))
											.multilineTextAlignment(.center)
										Spacer()
//										Button(action:{ }, label:{ Image(systemName:"ellipsis.circle.fill") })
//											.font(.system(size:20))
//											.foregroundColor(Color("AccentColor"))
//											.padding(8)
									}
									.padding(8)
									.background(Color("BackgroundCard"))
									.cornerRadius(12)
								}
							}
						}
						.padding()
					}
					.zIndex(page == .friends ? 0 : -1)
					.disabled(page != .friends)
					.opacity(page == .friends ? 1 : 0)
				}
				.padding(.top, -8)
				.frame(maxWidth:.infinity)
				.alert(isPresented:$showBaseAlert)
				{
					Alert(
						title: Text(baseAlertText),
						dismissButton: .default(Text("OK")) {
							guard returnToLoginAfterAlert else { return }
							returnToLoginAfterAlert = false
							logout()
						}
					)
				}

				// Page controls
				HStack()
				{
					Spacer()
					Button(action:{ page = .hosts }, label:
					{
						VStack()
						{
							Image(systemName:"desktopcomputer")
							Text("Hosts")
						}
					})
					.foregroundColor(Color(page == .hosts ? "AccentColor" : "ForegroundInactive"))
					.disabled(page == .hosts)
					Spacer()
					Button(action:{ page = .friends }, label:
					{
						VStack()
						{
							Image(systemName:"person.2.fill")
							Text("Friends")
						}
					})
					.foregroundColor(Color(page == .friends ? "AccentColor" : "ForegroundInactive"))
					.disabled(page == .friends)
					Spacer()
				}
				.padding([.leading, .bottom, .trailing], 4)
				.background(Color("BackgroundTab")
					.padding(.top, -8)
					.shadow(color:Color("Shading"), radius:4, y:-2)
					.mask(Rectangle().frame(height:80).offset(y:-50))
				)
				.zIndex(1)
			}
			.onAppear(perform:initView)
			.disabled(busy) // disable view if busy

			// Settings screen
			SettingsView(visible:$inSettings)

			// Loading elements
			if isConnecting
			{
				ZStack()
				{
					Rectangle() // Darken background
						.fill(Color.black)
						.opacity(0.5)
						.edgesIgnoringSafeArea(.all)
					VStack()
					{
						ActivityIndicator(isAnimating:$isConnecting, style:.large, tint:.white)
							.padding()
						Text("Requesting connection to \(connectingToName)...")
							.multilineTextAlignment(.center)
						Button(action:cancelConnection)
						{
							ZStack()
							{
								Rectangle()
									.fill(Color("BackgroundButton"))
									.cornerRadius(8)
								Text("Cancel")
									.foregroundColor(.red)
							}
						}
						.frame(maxWidth:100, maxHeight:48)
					}
					.padding()
					.background(Rectangle().fill(Color("BackgroundPrompt")))
					.cornerRadius(8)
					.padding()
				}
				.accessibilityIdentifier("openparsec.connection.pending")
			}
			if isRefreshing
			{
				ZStack()
				{
					Rectangle() // Darken background
						.fill(Color.black)
						.opacity(0.5)
						.edgesIgnoringSafeArea(.all)
					VStack()
					{
						ActivityIndicator(isAnimating:$isRefreshing, style:.large, tint:.white)
							.padding()
						Text("Refreshing hosts...")
							.multilineTextAlignment(.center)
					}
					.padding()
					.background(Rectangle().fill(Color("BackgroundPrompt")))
					.cornerRadius(8)
					.padding()
				}
			}

			if OpenParsecRuntime.isUITesting {
				SessionDiagnosticsAccessibilityView(exposesPhase: false)
			}
		}
		.foregroundColor(Color("Foreground"))
	}

	func initView()
	{
		CParsec.configureMediaRecovery()
		ParsecBackgroundManager.shared.onShouldReconnect = { request in
			let displayName = lastConnectedPeerName.isEmpty
				? "Previous host"
				: lastConnectedPeerName
			connectToPeerID(
				request.peerID,
				displayName: displayName,
				intent: .reconnect
			)
		}

		if OpenParsecRuntime.isUITesting {
			switch OpenParsecRuntime.uiTestAPIFailure {
			case "expired-auth":
				presentAPIFailure(
					ParsecAPIFailure(
						endpoint: .hosts,
						category: .sessionExpired,
						statusCode: 401,
						retryable: false,
						requiresSignIn: true
					)
				)
				return
			case "missing-host":
				hosts = []
				hostCountStr = "0 hosts"
				presentAPIFailure(
					ParsecAPIFailure(
						endpoint: .hosts,
						category: .missingResource,
						statusCode: 404,
						retryable: false,
						requiresSignIn: false
					)
				)
				return
			default:
				break
			}

			hosts = [
				IdentifiableHostInfo(
					id: Self.uiTestPeerID,
					hostname: "OpenParsec Fake Host",
					user: UserInfo(id: 1, name: "OpenParsec Test", warp: false, team_id: "test"),
					connections: 0
				)
			]
			hostCountStr = "1 host"
			refreshTime = "Deterministic test host"
			return
		}

		refreshData()
	}

	private func beginRefresh(requestCount: Int) -> UInt64 {
		let generation = refreshTracker.begin(requestCount: requestCount)
		isRefreshing = refreshTracker.isRefreshing
		return generation
	}

	private func finishRefresh(generation: UInt64) {
		guard refreshTracker.finish(generation: generation) else { return }
		isRefreshing = refreshTracker.isRefreshing
	}

	private func presentAPIFailure(_ failure: ParsecAPIFailure) {
		// An expired session takes precedence over lower-severity concurrent
		// refresh failures and is resolved after the user acknowledges it.
		if returnToLoginAfterAlert && !failure.requiresSignIn { return }
		if failure.requiresSignIn {
			NetworkHandler.clinfo = nil
			returnToLoginAfterAlert = true
		}
		baseAlertText = failure.message
		showBaseAlert = true
	}

	private func refreshData() {
		let generation = beginRefresh(requestCount: 3)
		refreshHosts(generation: generation)
		refreshSelf(generation: generation)
		refreshFriends(generation: generation)
	}

	func refreshHosts() {
		let generation = beginRefresh(requestCount: 1)
		refreshHosts(generation: generation)
	}

	private func refreshHosts(generation: UInt64)
	{
		withAnimation
		{

			guard let clinfo = NetworkHandler.clinfo else {
				presentAPIFailure(
					ParsecAPIFailure(
						endpoint: .hosts,
						category: .sessionExpired,
						statusCode: 401,
						retryable: false,
						requiresSignIn: true
					)
				)
				finishRefresh(generation: generation)
				return
			}

			let apiURL = URL(string:"https://kessel-api.parsec.app/v2/hosts?mode=desktop&public=false")!

			var request = URLRequest(url:apiURL)
			request.httpMethod = "GET"
			request.setValue("application/json", forHTTPHeaderField:"Content-Type")
			request.setValue("Bearer \(clinfo.session_id)", forHTTPHeaderField:"Authorization")
			request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")

			let task = URLSession.shared.dataTask(with:request)
			{ (data, response, error) in
				DispatchQueue.main.async {
					guard refreshTracker.accepts(generation: generation) else { return }
					defer { finishRefresh(generation: generation) }
					if let data = data, let http = response as? HTTPURLResponse
					{
						let statusCode:Int = http.statusCode
						let decoder = JSONDecoder()
						let decoded = try? decoder.decode(HostInfoList.self, from: data)
						if let failure = ParsecAPIResponseClassifier.classify(
							endpoint: .hosts,
							statusCode: statusCode,
							transportFailed: error != nil,
							decodedSuccessfully: decoded != nil
						) {
							hosts.removeAll()
							hostCountStr = "Hosts unavailable"
							presentAPIFailure(failure)
							return
						}

						if statusCode == 200 // 200 OK
						{
							if let info = decoded
							{
								hosts.removeAll()
								if let datas = info.data
								{
									datas.forEach
									{ h in
										hosts.append(IdentifiableHostInfo(id:h.peer_id, hostname:h.name, user:h.user, connections:h.players))
									}
								}

								var grammar: String = "hosts"
								if hosts.count == 1
								{
									grammar = "host"
								}

								hostCountStr = "\(hosts.count) \(grammar)"

								let formatter = DateFormatter()
								formatter.dateFormat = "M/d/yyyy h:mm a"
								refreshTime = "Last refreshed at \(formatter.string(from:Date()))"
							}
						}
					}
					else if let failure = ParsecAPIResponseClassifier.classify(
						endpoint: .hosts,
						statusCode: nil,
						transportFailed: true,
						decodedSuccessfully: false
					) {
						hosts.removeAll()
						hostCountStr = "Hosts unavailable"
						presentAPIFailure(failure)
					}
				}
			}
			task.resume()
		}
	}

	private func refreshSelf(generation: UInt64)
	{
		withAnimation
		{
			guard let clinfo = NetworkHandler.clinfo else {
				presentAPIFailure(
					ParsecAPIFailure(
						endpoint: .currentUser,
						category: .sessionExpired,
						statusCode: 401,
						retryable: false,
						requiresSignIn: true
					)
				)
				finishRefresh(generation: generation)
				return
			}

			let apiURL = URL(string:"https://kessel-api.parsec.app/me")!

			var request = URLRequest(url:apiURL)
			request.httpMethod = "GET"
			request.setValue("application/json", forHTTPHeaderField:"Content-Type")
			request.setValue("Bearer \(clinfo.session_id)", forHTTPHeaderField:"Authorization")
			request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")

			let task = URLSession.shared.dataTask(with:request)
			{ (data, response, error) in
				DispatchQueue.main.async {
					guard refreshTracker.accepts(generation: generation) else { return }
					defer { finishRefresh(generation: generation) }
					if let data = data, let http = response as? HTTPURLResponse
					{
						let statusCode:Int = http.statusCode
						let decoder = JSONDecoder()
						let decoded = try? decoder.decode(SelfInfo.self, from: data)
						if let failure = ParsecAPIResponseClassifier.classify(
							endpoint: .currentUser,
							statusCode: statusCode,
							transportFailed: error != nil,
							decodedSuccessfully: decoded != nil
						) {
							userInfo = nil
							presentAPIFailure(failure)
							return
						}

						if statusCode == 200 // 200 OK
						{
							if let selfData = decoded?.data
							{
								userInfo = IdentifiableUserInfo(id:selfData.id, username:selfData.name)
							}
						}
					}
					else if let failure = ParsecAPIResponseClassifier.classify(
						endpoint: .currentUser,
						statusCode: nil,
						transportFailed: true,
						decodedSuccessfully: false
					) {
						userInfo = nil
						presentAPIFailure(failure)
					}
				}
			}
			task.resume()
		}
	}

	private func refreshFriends(generation: UInt64)
	{
		withAnimation
		{
			guard let clinfo = NetworkHandler.clinfo else {
				presentAPIFailure(
					ParsecAPIFailure(
						endpoint: .friends,
						category: .sessionExpired,
						statusCode: 401,
						retryable: false,
						requiresSignIn: true
					)
				)
				finishRefresh(generation: generation)
				return
			}

			let apiURL = URL(string:"https://kessel-api.parsec.app/friendships")!

			var request = URLRequest(url:apiURL)
			request.httpMethod = "GET"
			request.setValue("application/json", forHTTPHeaderField:"Content-Type")
			request.setValue("Bearer \(clinfo.session_id)", forHTTPHeaderField:"Authorization")
			request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")

			let task = URLSession.shared.dataTask(with:request)
			{ (data, response, error) in
				DispatchQueue.main.async {
					guard refreshTracker.accepts(generation: generation) else { return }
					defer { finishRefresh(generation: generation) }
					if let data = data, let http = response as? HTTPURLResponse
					{
						let statusCode:Int = http.statusCode
						let decoder = JSONDecoder()
						let decoded = try? decoder.decode(FriendInfoList.self, from: data)
						if let failure = ParsecAPIResponseClassifier.classify(
							endpoint: .friends,
							statusCode: statusCode,
							transportFailed: error != nil,
							decodedSuccessfully: decoded != nil
						) {
							friends.removeAll()
							friendCountStr = "Friends unavailable"
							presentAPIFailure(failure)
							return
						}

						if statusCode == 200 // 200 OK
						{
							if let info = decoded
							{
								friends.removeAll()
								if let datas = info.data
								{
									datas.forEach
									{ f in
										friends.append(IdentifiableUserInfo(id:f.user_id, username:f.user_name))
									}
								}

								var grammar: String = "friends"
								if friends.count == 1
								{
									grammar = "friend"
								}

								friendCountStr = "\(friends.count) \(grammar)"
							}
						}
					}
					else if let failure = ParsecAPIResponseClassifier.classify(
						endpoint: .friends,
						statusCode: nil,
						transportFailed: true,
						decodedSuccessfully: false
					) {
						friends.removeAll()
						friendCountStr = "Friends unavailable"
						presentAPIFailure(failure)
					}
				}
			}
			task.resume()
		}
	}

	func connectTo(
		_ who: IdentifiableHostInfo,
		intent: ParsecConnectIntent = .initial
	)
	{
		connectToPeerID(
			who.id,
			displayName: who.hostname,
			intent: intent
		)
	}

	private func connectToPeerID(
		_ peerID: String,
		displayName: String,
		intent: ParsecConnectIntent
	)
	{
		CParsec.initialize()
		connectingToName = displayName
		lastConnectedPeerName = displayName
		withAnimation { isConnecting = true }

		pollTimer?.invalidate()
		pollTimer = nil
		// The runner retries transient network failures (-6013 & co.) itself,
		// so an alert here means the host is genuinely unreachable.
		ParsecConnectRunner.shared.start(peerID: peerID, intent: intent) { status in
			withAnimation { isConnecting = false }
			if status == .ok {
				controller?.setView(.parsec)
				return
			}
			if intent == .reconnect {
				// Terminal for this recovery episode: a later foreground must not
				// schedule another generation behind the user's back.
				ParsecBackgroundManager.shared.disableAutoReconnect()
			}
			baseAlertText = ParsecStatusBar.failureMessage(forCode: Int(status.rawValue), connecting: true)
			showBaseAlert = true
		}
	}

	func cancelConnection()
	{
		withAnimation { isConnecting = false }

		ParsecConnectRunner.shared.cancel()
		ParsecBackgroundManager.shared.disableAutoReconnect()
		CParsec.disconnect()

		// Q2: pollTimer is nil if Cancel is tapped before the connect poll
		// timer schedules — the old force-unwrap crashed on that race.
		pollTimer?.invalidate()
		pollTimer = nil
	}

	func logout()
	{
		removeFromKeychain(key:GLBDataModel.shared.SessionKeyChainKey)
		NetworkHandler.clinfo = nil
		if let c = controller
		{
			c.setView(.login)
		}
	}

	func removeFromKeychain(key: String)
	{
		let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
		let status = SecItemDelete(query as CFDictionary)
		if status == errSecSuccess
		{
			print("Successfully removed data from keychain.")
		}
	}
}

struct MainView_Previews:PreviewProvider
{
	static var previews: some View
	{
		MainView(nil)
	}
}

struct IdentifiableHostInfo:Identifiable
{
	var id: String // Peer ID
	var hostname: String // Computer's Display Name
	var user: UserInfo // User Data
	var connections:Int // User's Connected To This Host
}

struct IdentifiableUserInfo:Identifiable
{
	var id:Int // User ID
	var username: String // User Display Name
}

private enum Page
{
	case hosts
	case friends
}
