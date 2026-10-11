import GLKit
import UIKit

// Freeze evidence for device logs. Distinguishes, per stall:
//   frameAge  large, drawAge small → no new frames from host/network
//   drawAge   large                → client render loop stopped
//   pollGap   large                → client main thread hung
// lastNewFrameAt is set from the SDK pre-render callback, which fires only
// for NEW host frames (re-draws of the previous frame don't call it).
enum RenderClock {
	static var lastDrawAt: CFTimeInterval = 0
	static var lastNewFrameAt: CFTimeInterval = 0
	private static var lastPollAt: CFTimeInterval = 0
	private static var stalled = false

	/// Main thread, from the 0.2 s session status poll.
	static func check(paused: Bool, detail: @autoclosure () -> String) {
		let now = CACurrentMediaTime()
		// > 5 s means polling was suspended (background), not a hang.
		let pollGap = (lastPollAt == 0 || now - lastPollAt > 5) ? 0 : now - lastPollAt
		lastPollAt = now
		guard lastNewFrameAt > 0 else { return }
		let frameAge = now - lastNewFrameAt
		let drawAge = now - lastDrawAt
		// ponytail: 2 s for frames — a static host screen with Constant FPS off
		// may legitimately send nothing; that shows up here as a host-side stall.
		let stalledNow = frameAge > 2 || drawAge > 0.5 || pollGap > 0.5
		let ms = { (t: CFTimeInterval) in Int(t * 1000) }
		if stalledNow && !stalled {
			stalled = true
			Diagnostics.note("render-stall frameAgeMs=\(ms(frameAge)) drawAgeMs=\(ms(drawAge)) pollGapMs=\(ms(pollGap)) paused=\(paused) \(detail())")
		} else if !stalledNow && stalled {
			stalled = false
			Diagnostics.note("render-resume frameAgeMs=\(ms(frameAge)) drawAgeMs=\(ms(drawAge))")
		}
	}
}

class ParsecGLKRenderer:NSObject, GLKViewDelegate, GLKViewControllerDelegate
{
	var glkView:GLKView
	var glkViewController:GLKViewController
	
	var lastSize = CGSize(width: 1.0, height: 1.0)
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
		if widthChanged || heightChanged {
			synchronizeDimensions()
		}

		// Never wait for a frame here: this runs on the main thread every display
		// tick. A host at ~53 fps leaves most 120 Hz ticks without a new frame,
		// and the old 8–16 ms wait blocked main for 60–75% of each tick (judder,
		// uneven input latency). With timeout 0 the SDK draws the newest frame
		// or re-draws the previous one and returns (parsec.h).
		RenderClock.lastDrawAt = CACurrentMediaTime()
		let result = CParsec.renderGLFrame(timeout: 0)
		let generation = CParsec.sessionSnapshot.generation
		if result.producedFrame && lastLoggedRenderGeneration != generation {
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

	func synchronizeDimensions() {
		guard UIApplication.shared.applicationState == .active else { return }
		let size = glkView.bounds.size
		guard size.width > 0, size.height > 0 else { return }
		CParsec.setFrame(size.width, size.height, glkView.contentScaleFactor)
		lastSize = size
		Diagnostics.note(
			"render-dimensions generation=\(CParsec.sessionSnapshot.generation) " +
			"width=\(Int(size.width)) height=\(Int(size.height)) " +
			"scale=\(glkView.contentScaleFactor) " + geometryDescription()
		)
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
