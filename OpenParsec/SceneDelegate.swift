import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
	var window: UIWindow?

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
	{
		let contentView = ContentView()

		if let windowScene = scene as? UIWindowScene
		{
		    let window = UIWindow(windowScene: windowScene)
		    window.rootViewController = UIHostingController(rootView: contentView)
		    self.window = window
		    window.makeKeyAndVisible()
		}
	}

	func sceneDidDisconnect(_ scene: UIScene) {
	}

	func sceneDidBecomeActive(_ scene: UIScene)
	{
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.stopPiP()
		}
		ParsecBackgroundManager.shared.sceneDidBecomeActive()
	}

	func sceneWillResignActive(_ scene: UIScene)
	{
		// Do NOT start PiP here — fires for app switcher gesture too. PiP starts in sceneDidEnterBackground.
		ParsecBackgroundManager.shared.sceneWillResignActive()
	}

	func sceneWillEnterForeground(_ scene: UIScene)
	{
	}

	func sceneDidEnterBackground(_ scene: UIScene)
	{
		guard ParsecBackgroundManager.shared.hasActiveConnection else { return }
		// Really backgrounded (not just inactive): stop the video stream before
		// iPadOS invalidates VideoToolbox (ParsecSDKBridge.setVideoSuspended).
		CParsec.setVideoSuspended(true, stopStream: true)

		var pipAttempted = false
		if #available(iOS 15.0, *), !OpenParsecRuntime.disablesPiP {
			PictureInPictureManager.shared.startPiP(
				generation: CParsec.sessionSnapshot.generation
			)
			pipAttempted = PictureInPictureManager.shared.isPiPActive
		}

		// PiP keeps the stream alive in the background; its own stop/fail
		// callbacks own the disconnect from there. Without PiP, hold a short
		// keep-alive window so a quick app-switch resumes instantly instead of
		// forcing a full reconnect.
		ParsecBackgroundManager.shared.sceneDidEnterBackground(
			pipProtected: pipAttempted,
			audioKeepAlive: CParsec.isAudioKeepAliveActive
		)
	}
}
