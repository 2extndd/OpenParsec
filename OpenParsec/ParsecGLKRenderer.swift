import GLKit
import UIKit

// Freeze evidence for device logs. Distinguishes, per stall:
//   videoDead                      → SDK decoder failed (frozen picture)
//   drawAge   large                → client render loop stopped
//   pollGap   large                → client main thread hung
// The SDK exposes no new-frame signal: its pre-render callback fires on every
// RenderFrame call, re-draws of the previous frame included (ParsecSDK
// 0x7ccf0), so it cannot tell a frozen picture from a live one.
enum RenderClock {
	static var lastDrawAt: CFTimeInterval = 0
	private static var lastPollAt: CFTimeInterval = 0
	private static var stalled = false

	/// Main thread, from the 0.2 s session status poll.
	static func check(videoDead: Bool, paused: Bool, detail: @autoclosure () -> String) {
		let now = CACurrentMediaTime()
		// > 5 s means polling was suspended (background), not a hang.
		let pollGap = (lastPollAt == 0 || now - lastPollAt > 5) ? 0 : now - lastPollAt
		lastPollAt = now
		guard lastDrawAt > 0 else { return }
		let drawAge = now - lastDrawAt
		let stalledNow = videoDead || drawAge > 0.5 || pollGap > 0.5
		let ms = { (t: CFTimeInterval) in Int(t * 1000) }
		if stalledNow && !stalled {
			stalled = true
			Diagnostics.note("render-stall videoDead=\(videoDead) drawAgeMs=\(ms(drawAge)) pollGapMs=\(ms(pollGap)) paused=\(paused) \(detail())")
		} else if !stalledNow && stalled {
			stalled = false
			Diagnostics.note("render-resume drawAgeMs=\(ms(drawAge))")
		}
	}
}

class ParsecGLKRenderer:NSObject, GLKViewDelegate, GLKViewControllerDelegate
{
	var glkView:GLKView
	var glkViewController:GLKViewController
	
	var lastSize = CGSize(width: 1.0, height: 1.0)
	private var syncedGeneration: UInt64?
	private var lastLoggedRenderGeneration: UInt64?

	var lastImg: CGImage?
	let updateImage: () -> Void
	
	init(_ view:GLKView, _ viewController:GLKViewController,_ updateImage: @escaping () -> Void)
	{
		self.updateImage = updateImage
		glkView = view
		glkViewController = viewController

		super.init()

		glkView.delegate = self
		glkViewController.delegate = self

	}

	deinit
	{
		glkView.delegate = nil
		glkViewController.delegate = nil
	}

	func glkView(_ view:GLKView, drawIn rect:CGRect)
	{
		let size = view.bounds.size
		let widthChanged = abs(size.width - lastSize.width) > 0.1
		let heightChanged = abs(size.height - lastSize.height) > 0.1
		// Every connect (changeResolution's .reconfigure, reconnects) is a new
		// SDK session that knows no window size: without this the first frames
		// of the new stream drew stretched over the whole drawable (device log:
		// viewport=0,0,2421,1668 for a 3024x1964 stream) until some unrelated
		// resize happened.
		let sessionGeneration = CParsec.sessionSnapshot.generation
		if widthChanged || heightChanged || syncedGeneration != sessionGeneration,
		   synchronizeDimensions() {
			// Recorded only once it reached the SDK (skipped while inactive).
			syncedGeneration = sessionGeneration
		}

		// Never wait for a frame here: this runs on the main thread every display
		// tick. A host at ~53 fps leaves most 120 Hz ticks without a new frame,
		// and the old 8–16 ms wait blocked main for 60–75% of each tick (judder,
		// uneven input latency). With timeout 0 the SDK draws the newest frame
		// or re-draws the previous one and returns (parsec.h).
		RenderClock.lastDrawAt = CACurrentMediaTime()
		let result = CParsec.renderGLFrame(timeout: 0)
		let generation = CParsec.sessionSnapshot.generation
		if result.producedFrame && lastLoggedRenderGeneration != generation,
		   // SetDimensions while the session was still connecting may not
		   // stick; the session is certainly running once it produced a frame.
		   synchronizeDimensions() {
			lastLoggedRenderGeneration = generation
			Diagnostics.note(
				"render-geometry event=first-produced generation=\(generation) " +
				geometryDescription()
			)
		}

		// Feed one pre-roll sample before PiP starts, then capture only while a
		// transition or active PiP needs frames. captureFrame owns that policy,
		// so this hook stays cheap after the first prepared sample.
		if #available(iOS 15.0, *), !OpenParsecRuntime.disablesPiP {
			PictureInPictureManager.shared.captureFrame(
				viewWidth: GLsizei(view.drawableWidth),
				viewHeight: GLsizei(view.drawableHeight),
				streamWidth: GLsizei(CParsec.hostWidth),
				streamHeight: GLsizei(CParsec.hostHeight)
			)
		}

		updateImage()

//		glFinish()
		//glFlush()
	}

	@discardableResult
	func synchronizeDimensions() -> Bool {
		guard UIApplication.shared.applicationState == .active else { return false }
		let size = glkView.bounds.size
		guard size.width > 0, size.height > 0 else { return false }
		CParsec.setFrame(size.width, size.height, glkView.contentScaleFactor)
		lastSize = size
		return true
		// No log here: this runs per frame during a resize animation. The
		// settled result is logged once by ParsecViewController.
	}

	private func geometryDescription() -> String {
		var viewport = [GLint](repeating: 0, count: 4)
		let contextCurrent = EAGLContext.current() === glkView.context
		if contextCurrent {
			viewport.withUnsafeMutableBufferPointer { buffer in
				glGetIntegerv(GLenum(GL_VIEWPORT), buffer.baseAddress)
			}
		}
		return "drawable=\(glkView.drawableWidth)x\(glkView.drawableHeight) " +
			"viewport=\(viewport[0]),\(viewport[1]),\(viewport[2]),\(viewport[3]) " +
			"contextCurrent=\(contextCurrent)"
	}

	func glkViewControllerUpdate(_ controller:GLKViewController) { }
}
