//import SwiftUI
//import GLKit
//
//struct ParsecGLKViewController: UIViewControllerRepresentable
//{
//	let glkView = GLKView()
//	let glkViewController = GLKViewController()
//	let onBeforeRender:() -> Void
//
//	func makeCoordinator() -> ParsecGLKRenderer
//	{
//		ParsecGLKRenderer(glkView, glkViewController, onBeforeRender)
//	}
//
//	func makeUIViewController(context: UIViewControllerRepresentableContext<ParsecGLKViewController>) -> GLKViewController
//	{
//		glkView.context = EAGLContext(api:.openGLES3)!
//		glkViewController.view = glkView
//		glkViewController.preferredFramesPerSecond = 60
//		return glkViewController
//	}
//
//	func updateUIViewController(_ uiViewController:GLKViewController, context: UIViewControllerRepresentableContext<ParsecGLKViewController>) { }
//}

import UIKit
import GLKit

class ParsecGLKViewController : ParsecPlayground {

	var glkView: GLKView!
	let glkViewController = GLKViewController()
	var glkRenderer: ParsecGLKRenderer!
	let updateImage:() -> Void
	
	// unowned: the ParsecViewController owns this surface; a strong ref leaked
	// every session controller together with a live render loop.
	unowned let viewController: UIViewController
	
	required init(viewController: UIViewController, updateImage: @escaping () -> Void) {
		self.viewController = viewController
		self.updateImage = updateImage
	}

	public func viewDidLoad() {
		glkView = GLKView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
		glkRenderer = ParsecGLKRenderer(glkView, glkViewController, updateImage)
		self.viewController.view.addSubview(glkView)
		setupGLKViewController()
		

	}

	private func setupGLKViewController() {
		glkView.context = EAGLContext(api: .openGLES3)!
		// Track the superview's bounds so the drawable can't desync / go
		// zero-size when the view is moved between parents or the layout
		// changes on screen return (R4). updateSize still drives explicit
		// resolution changes; this just keeps the surface pinned otherwise.
		glkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		glkViewController.view = glkView
		// ParsecViewController.appDidBecomeActive owns resume (after layout settles).
		glkViewController.resumeOnDidBecomeActive = false

		applyPreferredFrameRate()

		self.viewController.addChild(glkViewController)
		self.viewController.view.addSubview(glkViewController.view)
		self.glkViewController.didMove(toParent: self.viewController)
	}
	
	var eaglContext: EAGLContext? {
		return glkView?.context
	}

	// Symmetric stop: pause the CADisplayLink-driven render loop so
	// glkView(_:drawIn:) stops being called. Used when the surface is going
	// off screen; resume() reverses it.
	func cleanUp() {
		glkViewController.isPaused = true
	}

	// Fully detach one paused GLK surface before a replacement is created.
	// Keeping two child controllers alive can make the SDK render through a
	// stale EAGL context after reconnect.
	func detach() {
		glkViewController.isPaused = true
		glkView?.delegate = nil
		glkViewController.delegate = nil
		glkViewController.willMove(toParent: nil)
		glkViewController.view.removeFromSuperview()
		glkViewController.removeFromParent()
		if EAGLContext.current() === glkView?.context {
			_ = EAGLContext.setCurrent(nil)
		}
		glkRenderer = nil
		glkViewController.view = nil
		glkView = nil
	}

	// Idempotent render resume. Safe to call repeatedly. Makes the EAGL
	// context current on the main thread (where GLKViewController renders),
	// unpauses the loop LAST (Apple's ordering rule), then forces one frame
	// so a stale/blank framebuffer repaints immediately instead of waiting
	// for the next streamed frame. This is the core fix for the black screen
	// on screen return: any path that left isPaused == true (changeResolution,
	// PiP, background) is self-healed here.
	func resume() {
		// GL work while backgrounded gets the process killed by iOS.
		guard UIApplication.shared.applicationState != .background else { return }
		if let ctx = glkView?.context {
			_ = EAGLContext.setCurrent(ctx)
		}
		glkViewController.isPaused = false
		glkView?.setNeedsDisplay()
	}

	func synchronizeDimensions() {
		guard UIApplication.shared.applicationState != .background else { return }
		glkRenderer?.synchronizeDimensions()
		glkView?.setNeedsDisplay()
	}

	func applyPreferredFrameRate() {
		let fps = SettingsHandler.preferredFramesPerSecond
		glkViewController.preferredFramesPerSecond = fps == 0
			? Int(UIScreen.main.maximumFramesPerSecond)
			: fps
	}

	func updateSize(width: CGFloat, height: CGFloat) {
		glkView.frame.size.width = width
		glkView.frame.size.height = height
	}

	
}
