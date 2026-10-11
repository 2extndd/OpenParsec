import Foundation
import OSLog
import UIKit
import GameController

extension Notification.Name {
	static let parsecPointerBehaviorDidChange = Notification.Name(
		"ParsecPointerBehaviorDidChange"
	)
}

protocol ParsecPlayground {
	init(viewController: UIViewController, updateImage: @escaping () -> Void)
	func viewDidLoad()
	func cleanUp()
	// Idempotent render resume — re-currents the GL context and unpauses the
	// render loop. Called on screen return / app foreground to recover from a
	// paused or stale-drawable state (the black-screen-on-return bug).
	func resume()
	func updateSize(width: CGFloat, height: CGFloat)
}


class ParsecViewController: UIViewController, UIScrollViewDelegate {
	var glkView: ParsecPlayground!
	private var renderSurfaceGeneration: UInt64 = 0
	var gamePadController: GamepadController!
	var touchController: TouchController!
	var u: UIImageView?
	// Locally-rendered pointer dot for captured relative mode. Native mode uses
	// the unlocked iPadOS system pointer; touch-only fallback uses the host cursor.
	var localCursorImageView: UIView?
	var localCursorPosition: CGPoint = .zero
	// viewDidLoad runs before the contentView has a non-zero size, so seeding
	// the cursor there reads midX/Y as 0 and parks it at the corner. Re-seed
	// once layout produces real bounds. One-shot via this flag.
	var hasSeededLocalCursor: Bool = false
	private var nativePointerActive = false
	private var didInjectTestKeyboardKey = false
	private var didExecuteTestMacShortcut = false
	private var didExecuteTestWindowsShortcut = false
	private var didExecuteTestGamepadInput = false
	private var lastPublishedPointerDigest = ""
	private let pointerLogger = Logger(
		subsystem: "com.openparsec.client",
		category: "pointer"
	)
	private(set) static var pointerBehaviorSnapshot = ParsecPointerBehavior(
		mode: .native,
		nativePointerActive: false
	)
	var lastImg: CGImage?
    var lastMouseX: Int32 = -1
    var lastMouseY: Int32 = -1
    var lastCursorHidden: Bool = false
	var lastCursorScale = SettingsHandler.cursorScale
	var isPinching = false
	var zoomEnabled = false
	var pointerDeltaAccumulator = ParsecDeltaAccumulator()
	var lastPanLocation: CGPoint = .zero
	var lastPanTranslation: CGPoint = .zero

	// Trackpad momentum carries the same accumulator used by its live scroll.
	// Direct-touch two-finger scrolling stays separate so overlapping gesture
	// recognizers cannot consume each other's sub-pixel remainder.
	var trackpadScrollAccumulator = ParsecDeltaAccumulator()
	var touchScrollAccumulator = ParsecDeltaAccumulator()
	var lastScrollTranslation: CGPoint = .zero
	var lastTouchScrollTranslation: CGPoint = .zero

	// Client-side scroll inertia. The trackpad scroll path is driven by a raw
	// UIPanGestureRecognizer (allowedScrollTypesMask = .all, max 0 touches), NOT
	// a UIScrollView — and a raw recognizer gets NO OS-provided momentum tail
	// after the fingers lift (only UIScrollView synthesizes deceleration). So a
	// flick died instantly and the host saw no glide. S03 removed the old inertia
	// on the wrong assumption that "the OS momentum rides in for free"; it does
	// not on this recognizer, which is why inertia disappeared entirely.
	//
	// We re-seed a decaying glide from the PEAK velocity sampled during `.changed`
	// (gestureRecognizer.velocity at `.ended` is already near-zero because iPadOS
	// pre-decelerates its scroll-event stream) and drive it with a CADisplayLink.
	// BOTH the per-tick advance and the decay are scaled by the real frame
	// duration, so the glide distance is identical at 60 Hz and 120 Hz — fixing
	// the original bug (a hardcoded `peak/60` seed that doubled the glide on the
	// 120 Hz M4 iPad) without throwing away the feature.
	var momentumDisplayLink: CADisplayLink?
	var momentumVelocityX: Float = 0.0   // scaled host-wheel units / second
	var momentumVelocityY: Float = 0.0
	private var momentumElapsed: TimeInterval = 0
	private var peakScrollVelocityX: CGFloat = 0   // raw points / second
	private var peakScrollVelocityY: CGFloat = 0
	private var trackpadScrollTravel: CGFloat = 0
	// Glide tuning. Decay is expressed per-second and raised to dt each tick, so
	// it is frame-rate independent. Start/stop are in scaled units/sec (same
	// scale as momentumVelocity). These are deliberately conservative; the real
	// feel can only be judged on-device, so they are easy to nudge.
	private let scrollMomentumDecayPerSecond: Float = 0.02   // → ~2% of speed remains after 1 s
	private var scrollLiveUnits = 0
	private var scrollGlideUnits = 0
	private let scrollMomentumStopSpeed: Float = 24.0        // below this the glide ends

	// Layout sync — fires a hotkey at the host when the iPad's hardware-keyboard
	// input language changes (e.g. Caps Lock toggle on Magic Keyboard).
	var languageSync: LanguageSyncCoordinator?
	
	var activatedPanFingerNumber: Int = 0
	
	// Ctrl+Shift→Cmd+Space chord state machine (S05). `chordArmed` is true while
	// both Ctrl and Shift are held with nothing else pressed; `chordSawOtherKey`
	// trips the moment any non-modifier key joins the combo, so Ctrl+Shift+Arrow
	// (host selection) does NOT emulate Cmd+Space. We track held modifiers as a
	// small set of HID usages rather than reading event.modifierFlags so left/
	// right Ctrl and Shift are both honored and key-up bookkeeping is exact.
	private var heldModifierKeyCodes: Set<UIKeyboardHIDUsage> = []
	private var chordArmed: Bool = false
	private var chordSawOtherKey: Bool = false

	// Key-downs we deliberately swallowed (currently only the backtick→Cmd+Space
	// remap). Their matching key-up must be swallowed too, otherwise the host
	// receives a lone grave release and — worse — if the user holds the key, the
	// auto-repeat key-downs we drop but a single trailing key-up could desync.
	private var suppressedKeyUps: Set<UIKeyboardHIDUsage> = []

	var keyboardAccessoriesView : UIView?
	var keyboardHeight : CGFloat = 0.0
	var keyboardVisible : Bool = false
	private var keyboardWasVisibleBeforeResign = false
	private var pendingSurfaceGeneration: UInt64?
	var onKeyboardVisibilityChanged: ((Bool) -> Void)?
	var scrollView: UIScrollView!
	var contentView: UIView!

	// True while an in-session overlay (Settings) needs the local pointer:
	// unlocks the pointer and stops captured GCMouse input reaching the host.
	// Static because GCMouse handlers read it on GameController's queue.
	static var sessionOverlayActive = false

	override var prefersPointerLocked: Bool {
		pointerBehavior.prefersPointerLocked && !Self.sessionOverlayActive
	}
	
	override var prefersHomeIndicatorAutoHidden : Bool {
		return true
	}

	// With the pointer locked (prefersPointerLocked), iPadOS still owns a strip at
	// the bottom edge for the home-indicator / Control-Center swipe. Trackpad motion
	// landing in that strip is partly eaten by the system gesture and never reaches
	// our pointer handling, which the user feels as a dead-zone — and only inside
	// Parsec, because the pointer lock is unique to this screen. Deferring the system
	// edge gestures hands that strip back to the app. A second deliberate swipe still
	// reaches the system gesture, so Control-Center access is preserved.
	// Deferred for the whole session (not only when locked): the first swipe or
	// pointer push at an edge goes to the host instead of popping the iPad Dock;
	// a second deliberate one still reaches the system. Released while an
	// in-session overlay (Settings) is open.
	override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
		Self.sessionOverlayActive ? [] : .all
	}

	// Live controller count in diagnostics proves on device that leaving a
	// session frees it (a leak kept N render loops alive).
	private static var liveCount = 0

	init() {
		super.init(nibName: nil, bundle: nil)
		Self.liveCount += 1
		Diagnostics.note("session-vc event=init live=\(Self.liveCount)")

		self.glkView = ParsecGLKViewController(viewController: self, updateImage: { [weak self] in self?.updateImage() })

		self.gamePadController = GamepadController(viewController: self)
		self.touchController = TouchController(viewController: self)
	}
	
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	deinit {
		Self.liveCount -= 1
		Diagnostics.note("session-vc event=deinit live=\(Self.liveCount)")
		languageSync?.stop()
		stopScrollMomentum()
	}

	private var pointerBehavior: ParsecPointerBehavior {
		ParsecPointerBehavior(
			mode: SettingsHandler.pointerPresentationMode,
			nativePointerActive: nativePointerActive
		)
	}

	private func applyPointerBehavior(hostCursorHidden: Bool? = nil) {
		let behavior = pointerBehavior
		localCursorImageView?.isHidden = !behavior.showsLocalCursor
		if behavior.showsHostCursor {
			u?.isHidden = hostCursorHidden ?? CParsec.mouseInfo.cursorHidden
		} else {
			u?.isHidden = true
		}

		guard behavior.digest != lastPublishedPointerDigest else { return }
		lastPublishedPointerDigest = behavior.digest
		Self.pointerBehaviorSnapshot = behavior
		pointerLogger.info("pointer \(behavior.digest, privacy: .public)")
		NotificationCenter.default.post(
			name: .parsecPointerBehaviorDidChange,
			object: behavior
		)
	}

	func updateImage() {
        // Take ONE atomic snapshot of the cross-thread mouse state. Re-reading
        // CParsec.mouseInfo per field would each lock-and-copy separately and
        // could tear across a concurrent poll-thread write; the snapshot also
        // pins cursorImg's lifetime for the whole frame (C1 fix).
        let info = CParsec.mouseInfo
        let currentMouseX = info.mouseX
        let currentMouseY = info.mouseY
        let currentHidden = info.cursorHidden
        let currentImg = info.cursorImg

        // The presentation policy owns cursor visibility. Native hover uses
        // the immediate iPadOS system pointer, captured mode uses the local
        // overlay, and touch-only native sessions retain the host fallback.
        applyPointerBehavior(hostCursorHidden: currentHidden)
        guard pointerBehavior.showsHostCursor else { return }

        // Skip if nothing changed
        if currentMouseX == lastMouseX &&
           currentMouseY == lastMouseY &&
           currentHidden == lastCursorHidden &&
           currentImg == lastImg &&
           SettingsHandler.cursorScale == lastCursorScale {
            return
        }
        
        // Cursor Size changes must resize a stationary cursor too.
        lastCursorScale = SettingsHandler.cursorScale
        lastMouseX = currentMouseX
        lastMouseY = currentMouseY
        lastCursorHidden = currentHidden
        
		if currentImg != nil && !currentHidden {
			if lastImg != currentImg{
				u!.image = UIImage(cgImage: currentImg!)
				lastImg = currentImg!
			}

            // Using tracked values for bounds
			u?.frame = CGRect(x: Int(currentMouseX) - Int(Double(info.cursorHotX) * SettingsHandler.cursorScale),
							  y: Int(currentMouseY) - Int(Double(info.cursorHotY) * SettingsHandler.cursorScale),
							  width: Int(Double(info.cursorWidth) * SettingsHandler.cursorScale),
							  height: Int(Double(info.cursorHeight) * SettingsHandler.cursorScale))
            
			// Check bounds and pan if needed
			// Only pan if we are zoomed in OR if the keyboard is visible (to allow scrolling up)
			if scrollView.zoomScale > 1.0 || (keyboardVisible && scrollView.contentInset.bottom > 0) {
				let margin: CGFloat = 50.0
                
                // Convert cursor frame to screen coordinates (relative to the ViewController's view)
                // This accounts for zoom and current contentOffset automatically.
                let cursorFrameInScreen = contentView.convert(u!.frame, to: view)
                let viewBounds = view.bounds
                
                var targetOffsetX = scrollView.contentOffset.x
                var targetOffsetY = scrollView.contentOffset.y
                var shouldScroll = false
                
                // Check Left Edge
                if cursorFrameInScreen.minX < margin {
                    // We want the cursor to be at 'margin', so we shift contentOffset.
                    // NewOffset = CurrentOffset - (Margin - CurrentPos)
                    let diff = margin - cursorFrameInScreen.minX
                    targetOffsetX -= diff
                    shouldScroll = true
                }
                
                // Check Right Edge
                if cursorFrameInScreen.maxX > viewBounds.width - margin {
                    let diff = cursorFrameInScreen.maxX - (viewBounds.width - margin)
                    targetOffsetX += diff
                    shouldScroll = true
                }
                
                // Check Top Edge
                if cursorFrameInScreen.minY < margin {
                    let diff = margin - cursorFrameInScreen.minY
                    targetOffsetY -= diff
                    shouldScroll = true
                }
                
                // Check Bottom Edge
                // If keyboard is visible, the "bottom" is the top of the keyboard.
                let bottomInset = keyboardVisible ? keyboardHeight : 0.0
                let effectiveViewHeight = viewBounds.height - bottomInset
                
                if cursorFrameInScreen.maxY > effectiveViewHeight - margin {
                    let diff = cursorFrameInScreen.maxY - (effectiveViewHeight - margin)
                    targetOffsetY += diff
                    shouldScroll = true
                }
                
                if shouldScroll {
                    // Clamp to valid scroll range
                    // Including contentInset.bottom in calculation to allow scrolling past the original content size
                    let maxOffsetX = max(0, scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
                    let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
                    
                    targetOffsetX = max(-scrollView.contentInset.left, min(targetOffsetX, maxOffsetX))
                    targetOffsetY = max(-scrollView.contentInset.top, min(targetOffsetY, maxOffsetY))
                    
                    // Use a slightly smoother animation or immediate update? 
                    // 'updateImage' might be called frequently. animated: true might stack animations.
                    // For direct control, 'animated: false' is often snappier and prevents lag, 
                    // but 'true' is smoother visually. User asked for "image moves as mouse moves".
                    // Given high frequency, false is safer, or manual interpolation.
                    // Actually, standard UIScrollView behavior is usually direct setContentOffset.
                    scrollView.setContentOffset(CGPoint(x: targetOffsetX, y: targetOffsetY), animated: false)
                }
			}
			
		} else {
			u?.image = nil
		}
	}
	
	override func viewDidLoad() {
		Self.sessionOverlayActive = false
		// ScrollView Setup
		scrollView = UIScrollView(frame: view.bounds)
		scrollView.delegate = self
		scrollView.minimumZoomScale = 1.0
		scrollView.maximumZoomScale = 5.0
		// No autoresizing: layoutRenderSurface owns the frame.
		scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        /*
         We set minimumNumberOfTouches to 2 for the scroll view's pan gesture
         so that 1-finger drags are passed through to our custom gesture recognizers
         (for moving the mouse).
         Standard 2-finger pan will scroll the view.
         */
		view.addSubview(scrollView)

        // ContentView
		contentView = UIView(frame: view.bounds)
		scrollView.addSubview(contentView)
		scrollView.contentSize = view.bounds.size
		
        // Initialize GLKView
		glkView.viewDidLoad()
		
		// Move GLKView to ContentView
		// glkView.viewDidLoad() adds the view to 'view', we need to move it.
		if let parsecGLK = glkView as? ParsecGLKViewController {
			parsecGLK.glkView.removeFromSuperview()
			contentView.addSubview(parsecGLK.glkView)
		} else {
			// Fallback if type check fails, try to find the last subview added?
			// Assumption: glkView.viewDidLoad() adds a subview.
		}

		if #available(iOS 15.0, *), !OpenParsecRuntime.disablesPiP {
			if let parsecGLK = glkView as? ParsecGLKViewController,
			   let eaglContext = parsecGLK.eaglContext {
				PictureInPictureManager.shared.setup(sourceView: view, glContext: eaglContext, glkViewController: parsecGLK.glkViewController)
			}
		}

		touchController.viewDidLoad()
		gamePadController.viewDidLoad()

		u = UIImageView(frame: CGRect(x: 0,y: 0,width: 100, height: 100))
		contentView.addSubview(u!) // Add Cursor to ContentView

		// Local overlay cursor — iPadOS-style pointer dot drawn programmatically
		// so it actually looks native (the SF Symbol cursorarrow we tried
		// before was a Mac-style arrow that didn't match iPad muscle memory).
		// Light gray with a darker border for contrast on any background,
		// soft shadow for legibility. Same parent (contentView) so it scrolls
		// with the streamed content when the user is zoomed in.
		let dotSize: CGFloat = 13
		let localCursor = UIView(frame: CGRect(x: 0, y: 0, width: dotSize, height: dotSize))
		localCursor.backgroundColor = UIColor(white: 0.92, alpha: 0.85)
		localCursor.layer.cornerRadius = dotSize / 2
		localCursor.layer.borderWidth = 0.5
		localCursor.layer.borderColor = UIColor(white: 0.15, alpha: 0.45).cgColor
		localCursor.layer.shadowColor = UIColor.black.cgColor
		localCursor.layer.shadowOpacity = 0.35
		localCursor.layer.shadowRadius = 2.5
		localCursor.layer.shadowOffset = CGSize(width: 0, height: 1)
		localCursor.isUserInteractionEnabled = false
		localCursor.isHidden = !pointerBehavior.showsLocalCursor
		contentView.addSubview(localCursor)
		localCursorImageView = localCursor
		// The real seeding happens in viewDidLayoutSubviews — contentView's
		// bounds aren't valid until layout has run, so reading midX/Y here
		// would give (0, 0). Park at (0, 0) for now; the first layout pass
		// will move it to the centre.
		
		setNeedsUpdateOfPrefersPointerLocked()
		setNeedsUpdateOfScreenEdgesDeferringSystemGestures()

		let pointerInteraction = UIPointerInteraction(delegate: self)
		view.addInteraction(pointerInteraction)
		
		view.isMultipleTouchEnabled = true
		view.isUserInteractionEnabled = true

		let panGestureRecognizer = UIPanGestureRecognizer(target: self, action:#selector(self.handlePanGesture(_:)))
		panGestureRecognizer.delegate = self
		// Important: Allow our pan gesture to work alongside scrollview's?
		// No, we want 1 finger for this pan, 2 fingers for scrollview.
		// So they are distinct by touch count.
		// Exclude .indirectPointer (Magic Keyboard trackpad / iPad pointer) — those
		// events are handled directly via touchesMoved below to avoid the latency
		// of the gesture-recognizer state machine (issue #47: sticky cursor).
		panGestureRecognizer.allowedTouchTypes = [
			NSNumber(value: UITouch.TouchType.direct.rawValue),
			NSNumber(value: UITouch.TouchType.pencil.rawValue)
		]
		view.addGestureRecognizer(panGestureRecognizer)

		let hoverGestureRecognizer = UIHoverGestureRecognizer(
			target: self,
			action: #selector(handlePointerHover(_:))
		)
		view.addGestureRecognizer(hoverGestureRecognizer)

		// Hover intentionally describes pointer movement with no click. Magic
		// Keyboard click-drag needs a separate indirect-pointer pan route while
		// Native presentation remains unlocked.
		let nativeDragRecognizer = UIPanGestureRecognizer(
			target: self,
			action: #selector(handleNativePointerDrag(_:))
		)
		nativeDragRecognizer.allowedTouchTypes = [
			NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
		]
		nativeDragRecognizer.minimumNumberOfTouches = 1
		nativeDragRecognizer.maximumNumberOfTouches = 1
		nativeDragRecognizer.cancelsTouchesInView = false
		nativeDragRecognizer.delegate = self
		view.addGestureRecognizer(nativeDragRecognizer)

		// Dedicated recognizer for trackpad / mouse-wheel scroll events
		// (iPadOS 13.4+, available unconditionally at deployment target 14).
		// maximumNumberOfTouches = 0 makes it respond ONLY to scroll-wheel events,
		// not to fingers — so touchscreen 2-finger swipes still flow through the
		// main pan recognizer with allowedTouchTypes = direct + pencil.
		let trackpadScrollRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.handleTrackpadScroll(_:)))
		trackpadScrollRecognizer.delegate = self
		trackpadScrollRecognizer.allowedScrollTypesMask = .all
		trackpadScrollRecognizer.maximumNumberOfTouches = 0
		view.addGestureRecognizer(trackpadScrollRecognizer)

		// Remove custom Pinch logic, ScrollView handles it.
		// But we might want to know isPinching status?
        // Let's rely on ScrollView delegate for updates.
		
		// Add tap gesture recognizer for single-finger touch
		let singleFingerTapGestureRecognizer = UITapGestureRecognizer(target: self, action:#selector(handleSingleFingerTap(_:)))
		singleFingerTapGestureRecognizer.numberOfTouchesRequired = 1
		singleFingerTapGestureRecognizer.allowedTouchTypes = [0, 2]
		view.addGestureRecognizer(singleFingerTapGestureRecognizer)

		// Add tap gesture recognizer for two-finger touch
		let twoFingerTapGestureRecognizer = UITapGestureRecognizer(target: self, action:#selector(handleTwoFingerTap(_:)))
		twoFingerTapGestureRecognizer.numberOfTouchesRequired = 2
		twoFingerTapGestureRecognizer.allowedTouchTypes = [0]
		view.addGestureRecognizer(twoFingerTapGestureRecognizer)
		//		view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
		//		view.backgroundColor = UIColor(red: 0x66, green: 0xcc, blue: 0xff, alpha: 1.0)
		
		let threeFingerTapGestureRecognizer = UITapGestureRecognizer(target: self, action:#selector(handleThreeFinderTap(_:)))
		threeFingerTapGestureRecognizer.numberOfTouchesRequired = 3
		threeFingerTapGestureRecognizer.allowedTouchTypes = [0]
		view.addGestureRecognizer(threeFingerTapGestureRecognizer)
		
		let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action:#selector(handleLongPress(_:)))
		longPressGestureRecognizer.numberOfTouchesRequired = 1
		longPressGestureRecognizer.allowedTouchTypes = [0, 2]
		longPressGestureRecognizer.minimumPressDuration = ParsecTouchInteractionPolicy.dragMinimumPressDuration
		longPressGestureRecognizer.allowableMovement = ParsecTouchInteractionPolicy.dragAllowableMovement
		longPressGestureRecognizer.delegate = self
		// A successful drag owns the contact. Delay the one-finger tap until the
		// short-hold recognizer fails so one physical hold cannot emit drag and
		// then an extra click.
		singleFingerTapGestureRecognizer.require(toFail: longPressGestureRecognizer)
		view.addGestureRecognizer(longPressGestureRecognizer)
		
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillShow),
			name: UIResponder.keyboardWillShowNotification,
			object: nil
		)
		
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillHide),
			name: UIResponder.keyboardWillHideNotification,
			object: nil
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appWillResignActive),
			name: UIApplication.willResignActiveNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appDidBecomeActive),
			name: UIApplication.didBecomeActiveNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(settingDidChange),
			name: .parsecSettingDidChange,
			object: nil
		)

	}

	func replaceRenderSurfaceForReconnect(generation: UInt64) {
		dispatchPrecondition(condition: .onQueue(.main))
		guard isViewLoaded, contentView != nil else { return }
		// Creating a GL surface in the background gets the app killed; defer
		// to appDidBecomeActive.
		guard UIApplication.shared.applicationState != .background else {
			pendingSurfaceGeneration = generation
			return
		}
		pendingSurfaceGeneration = nil
		guard renderSurfaceGeneration != generation else {
			glkView?.resume()
			return
		}
		renderSurfaceGeneration = generation

		(glkView as? ParsecGLKViewController)?.detach()
		let replacement = ParsecGLKViewController(
			viewController: self,
			updateImage: { [weak self] in self?.updateImage() }
		)
		glkView = replacement
		replacement.viewDidLoad()
		replacement.glkView.removeFromSuperview()
		replacement.glkView.frame = contentView.bounds
		// Below the cursor overlays (u, local dot), like the original surface.
		contentView.insertSubview(replacement.glkView, at: 0)
		replacement.updateSize(
			width: contentView.bounds.width,
			height: contentView.bounds.height
		)
		replacement.resume()
		Diagnostics.note(
			"render-surface event=replaced generation=\(generation) " +
			"width=\(Int(contentView.bounds.width)) " +
			"height=\(Int(contentView.bounds.height))"
		)
	}

	func synchronizeRenderDimensions() {
		dispatchPrecondition(condition: .onQueue(.main))
		(glkView as? ParsecGLKViewController)?.synchronizeDimensions()
	}
	
	/// Single owner of the stream surface geometry (scrollView, contentView,
	/// GL view). The surface is exactly the app window — never larger than the
	/// screen, whatever frame SwiftUI hands this view (device log: 1408x991 on
	/// a 970 pt screen → drawable 2421x1704, image cropped and shifted) and
	/// independent of SwiftUI keyboard avoidance (the keyboard keeps working
	/// through scrollView.contentInset: content shifts, never rescales). The SDK
	/// then aspect-fits every stream size into it (ParsecClientGLRenderFrame,
	/// see ParsecResolution.aspectFit), so no resolution is stretched or cut.
	/// Before, contentView was resized only by rotation/foreground hooks that
	/// read a mid-animation size and kept it for the rest of the session.
	private func layoutRenderSurface(force: Bool = false) {
		guard isViewLoaded, scrollView != nil, contentView != nil else { return }
		var visible = view.bounds
		if let window = view.window {
			visible = view.convert(window.bounds, from: window)
		}
		visible = CGRect(
			x: visible.minX.rounded(),
			y: visible.minY.rounded(),
			width: visible.width.rounded(.down),
			height: visible.height.rounded(.down)
		)
		guard visible.width > 0, visible.height > 0 else { return }
		let changed = scrollView.frame != visible || contentView.bounds.size != visible.size
		if changed {
			// contentView is the zoom view: its frame is only meaningful at 1x.
			scrollView.setZoomScale(1.0, animated: false)
			scrollView.frame = visible
			contentView.frame = CGRect(origin: .zero, size: visible.size)
			scrollView.contentSize = visible.size
			glkView?.updateSize(width: visible.width, height: visible.height)
			clampAndApplyLocalCursor()
		}
		guard changed || force else { return }
		// Resize animations lay out every frame; tell the SDK and log once the
		// size has held still. The renderer already follows size changes per
		// frame, so this is the settled confirmation, not the only sync.
		renderGeometrySettle?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.renderGeometryDidSettle() }
		renderGeometrySettle = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
	}

	private var renderGeometrySettle: DispatchWorkItem?

	private func renderGeometryDidSettle() {
		guard UIApplication.shared.applicationState == .active else { return }
		let size = contentView.bounds.size
		guard size.width > 0, size.height > 0 else { return }
		let scale = (glkView as? ParsecGLKViewController)?.glkView?.contentScaleFactor
			?? view.contentScaleFactor
		// "Client Resolution" = the pixels the stream is actually shown in.
		ParsecResolution.updateClientResolution(
			width: Int((size.width * scale).rounded()),
			height: Int((size.height * scale).rounded())
		)
		synchronizeRenderDimensions()
		let stream = CGSize(width: CGFloat(CParsec.hostWidth), height: CGFloat(CParsec.hostHeight))
		let fit = ParsecResolution.aspectFit(stream, in: size)
		let px = { (v: CGFloat) in Int((v * scale).rounded()) }
		Diagnostics.note(
			"render-geometry event=settled view=\(Int(size.width))x\(Int(size.height)) " +
			"origin=\(Int(scrollView.frame.minX)),\(Int(scrollView.frame.minY)) " +
			"scale=\(String(format: "%.4f", scale)) pixels=\(px(size.width))x\(px(size.height)) " +
			"stream=\(Int(stream.width))x\(Int(stream.height)) " +
			"fit=\(px(fit.minX)),\(px(fit.minY)),\(px(fit.width)),\(px(fit.height))"
		)
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		layoutRenderSurface()
		// One-shot seed of the local cursor at the content view's centre
		// after layout has produced real bounds. viewDidLoad reads zero
		// bounds and would park the cursor at the corner.
		if !hasSeededLocalCursor && contentView.bounds.width > 0 && contentView.bounds.height > 0 {
			localCursorPosition = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
			localCursorImageView?.center = localCursorPosition
			hasSeededLocalCursor = true
		}
	}

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		glkView?.cleanUp()

		coordinator.animate(alongsideTransition: nil) { [weak self] _ in
			guard let self,
			      UIApplication.shared.applicationState == .active else { return }
			self.view.layoutIfNeeded()
			self.layoutRenderSurface(force: true)
			self.glkView.resume()

			// Reset accessory view to ensure correct width in new orientation.
			self.keyboardAccessoriesView = nil
			if self.keyboardVisible {
				self.reloadInputViews()
			}
		}
	}
	
	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		nativePointerActive = false
		applyPointerBehavior()
		if let parent = parent {
			parent.setChildForHomeIndicatorAutoHidden(self)
			parent.setChildViewControllerForPointerLock(self)
			parent.setChildForScreenEdgesDeferringSystemGestures(self)
		}
		if OpenParsecRuntime.holdsTestKeyboardKey,
		   !didInjectTestKeyboardKey {
			didInjectTestKeyboardKey = true
			CParsec.sendKeyboardMessage(
				event: KeyBoardKeyEvent(
					key: RemoteKeyCode(rawValue: 4),
					isPressBegin: true
				)
			)
		}
		if OpenParsecRuntime.executesTestMacShortcut,
		   !didExecuteTestMacShortcut {
			didExecuteTestMacShortcut = true
			CParsec.sendMacShortcut(.appSwitcher)
		}
		if OpenParsecRuntime.executesTestWindowsShortcut,
		   !didExecuteTestWindowsShortcut {
			didExecuteTestWindowsShortcut = true
			CParsec.sendWindowsShortcut(.startMenu)
		}
		if OpenParsecRuntime.executesTestGamepadInput,
		   !didExecuteTestGamepadInput {
			didExecuteTestGamepadInput = true
			// Press a supported button and an unsupported one, deflect a
			// stick, then release everything through the production path so
			// the UI test can prove no host button/axis is left stuck.
			CParsec.sendGameControllerButtonMessage(controllerId: 1, .a, pressed: true)
			CParsec.sendGameControllerButtonMessage(controllerId: 1, .guide, pressed: true)
			CParsec.sendGameControllerAxisMessage(controllerId: 1, .leftX, 900)
			CParsec.releaseAllGamepadInputs(reason: .normal)
		}
		if keyboardVisible {
			becomeFirstResponder()
		}
		scrollView.pinchGestureRecognizer?.isEnabled = zoomEnabled
		startLanguageSyncIfNeeded()
		// Recover the render loop on any return to this screen (SwiftUI
		// re-render, PiP exit, interrupted resolution change). Without this
		// a left-over isPaused == true keeps the surface frozen/black.
		layoutRenderSurface(force: true) // the window is attached only now
		glkView?.resume()
	}

	@objc private func appWillResignActive() {
		// Stop the display link before UIKit applies transient scene transforms.
		// Otherwise GLK autoresizing can publish portrait/ultrawide dimensions
		// to the SDK while the app is leaving the foreground.
		glkView?.cleanUp()
		// Pause host video; the stream itself is stopped only if the app really
		// goes to the background (SceneDelegate.sceneDidEnterBackground).
		CParsec.setVideoSuspended(true)
		// keyboardWillHide fires while backgrounding; remember the user's choice.
		keyboardWasVisibleBeforeResign = keyboardVisible
	}

	@objc private func appDidBecomeActive() {
		// Unpause (+ fresh decoder and keyframe after a real background), no reconnect.
		CParsec.setVideoSuspended(false)
		// App-switch gestures can leave UIScrollView's pinch/offset in an
		// intermediate zoom. At zoom > 1, scroll is intentionally consumed
		// locally instead of reaching the host, which looks like dead input.
		resetForegroundInteractionViewport()
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			if let generation = self.pendingSurfaceGeneration {
				self.replaceRenderSurfaceForReconnect(generation: generation)
			}
			if self.keyboardWasVisibleBeforeResign && !self.keyboardVisible {
				self.setKeyboardVisible(true)
			}
			self.setNeedsUpdateOfPrefersPointerLocked()
			self.view.layoutIfNeeded()
			// Recompute from the view, not the old contentView size: a size
			// captured mid app-switch animation used to persist from here.
			self.layoutRenderSurface(force: true)
			self.glkView.resume()
		}
	}

	@objc private func settingDidChange(_ notification: Notification) {
		guard let change = notification.object as? ParsecSettingChange else { return }

		switch change.id {
		case .syncKeyboardLayout:
			// The hidden field always runs (it holds first responder); the
			// coordinator's closure reads the setting on each change.
			break
		case .layoutSyncHotkey:
			// The coordinator reads the selected hotkey when the next distinct
			// input-mode change arrives, so no restart is required.
			break
		case .hostShortcutToolbarMode:
			keyboardAccessoriesView = nil
			if keyboardVisible {
				reloadInputViews()
			}
		case .windowsKeyboardMode:
			// Release physical keys through the adapter mapping latch before
			// clearing local bookkeeping so press and release stay paired.
			CParsec.releaseAllKeyboardKeys(reason: .settingsChanged)
			resetKeyboardBookkeeping()
		case .captureSystemKeys:
			// keyCommands is queried for each event and reads the canonical
			// setting live; receiving the change confirms the active controller.
			break
		case .preferredFramesPerSecond:
			(glkView as? ParsecGLKViewController)?.applyPreferredFrameRate()
		case .pointerPresentationMode:
			// Switching owner mid-hold must not strand a button on the host.
			CParsec.releaseAllMouseButtons(reason: .gestureCancelled)
			// Pointer lock is only re-queried when asked to.
			setNeedsUpdateOfPrefersPointerLocked()
			setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
		case .bitrate:
			// 0 = host default: keep the current stream rate.
			// 0 = host default; an equal value was already pushed by the
			// session menu, so skip a second encoder reconfigure.
			guard SettingsHandler.bitrate > 0,
				  DataManager.model.bitrate != SettingsHandler.bitrate else { return }
			DataManager.model.bitrate = SettingsHandler.bitrate
			CParsec.updateHostVideoConfig()
		default:
			return
		}

		Diagnostics.note(
			"setting-apply id=\(change.id.rawValue) mode=live result=applied"
		)
	}

	private func resetForegroundInteractionViewport() {
		let previousZoom = scrollView.zoomScale
		let previousOffset = scrollView.contentOffset
		stopScrollMomentum()
		lastScrollTranslation = .zero
		lastTouchScrollTranslation = .zero
		trackpadScrollAccumulator.reset()
		touchScrollAccumulator.reset()
		pointerDeltaAccumulator.reset()
		scrollView.layer.removeAllAnimations()
		scrollView.setZoomScale(1.0, animated: false)
		scrollView.setContentOffset(.zero, animated: false)
		Diagnostics.note(
			"foreground-viewport zoomBefore=\(String(format: "%.2f", previousZoom)) "
			+ "offsetBefore=\(Int(previousOffset.x)),\(Int(previousOffset.y)) "
			+ "zoomAfter=\(String(format: "%.2f", scrollView.zoomScale))"
		)
	}
	
	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		CParsec.releaseAllMouseButtons(reason: .viewDisappeared)
		CParsec.releaseAllKeyboardKeys(reason: .viewDisappeared)
		CParsec.releaseAllGamepadInputs(reason: .viewDisappeared)
		resetKeyboardBookkeeping()
		nativePointerActive = false
		applyPointerBehavior()
		if let parent = parent {
			parent.setChildForHomeIndicatorAutoHidden(nil)
			parent.setChildViewControllerForPointerLock(nil)
			parent.setChildForScreenEdgesDeferringSystemGestures(nil)
		}
		// Keyboard observers stay: they are added once in viewDidLoad, and the
		// same controller can reappear (removing them here broke the hidden
		// field's refocus → language sync after any disappear/appear cycle).
		stopLanguageSync()
		stopScrollMomentum()
	}
	
	
	@objc private func handlePointerHover(_ recognizer: UIHoverGestureRecognizer) {
		let route = pointerBehavior.inputRoute

		switch recognizer.state {
		case .began, .changed:
			guard ParsecPointerMotionOwnership.usesHover(
				route: route,
				pressedButtonCount: CParsec.mouseInputSnapshot.pressedCount
			) else {
				return
			}
			if !nativePointerActive {
				nativePointerActive = true
				applyPointerBehavior()
			}
			sendNativePointerPosition(recognizer.location(in: view))
		case .ended, .cancelled, .failed:
			nativePointerActive = false
			applyPointerBehavior()
		default:
			break
		}
	}

	private func sendNativePointerPosition(_ positionInView: CGPoint) {
		let position = contentView.convert(positionInView, from: view)
		let x = max(0, min(position.x, contentView.bounds.width))
		let y = max(0, min(position.y, contentView.bounds.height))
		CParsec.sendMousePosition(Int32(x), Int32(y))
	}

	@objc private func handleNativePointerDrag(_ recognizer: UIPanGestureRecognizer) {
		guard ParsecPointerMotionOwnership.usesNativeDragPan(
			route: pointerBehavior.inputRoute,
			pressedButtonCount: CParsec.mouseInputSnapshot.pressedCount
		) else {
			return
		}
		guard recognizer.state == .began || recognizer.state == .changed else {
			return
		}
		sendNativePointerPosition(recognizer.location(in: view))
	}

	// Direct trackpad pointer handling (issue #47). With prefersPointerLocked = true,
	// iPadOS delivers Magic Keyboard trackpad motion as UITouches with
	// type == .indirectPointer. Routing those through a UIPanGestureRecognizer
	// imposes a recognition threshold and a state-machine churn between strokes,
	// which is what users experience as the "sticky / juddery" cursor.
	//
	// The main pan recognizer's allowedTouchTypes excludes .indirectPointer
	// (see viewDidLoad), so those touches reach this override unobstructed.
	private func syncIndirectPointerButtons(
		buttonMask: UIEvent.ButtonMask,
		releaseReason: ParsecMouseReleaseReason = .normal
	) {
		let buttons = ParsecPointerButtonMaskSnapshot(buttonMask: buttonMask)
		CParsec.sendMouseClickMessage(
			.left,
			buttons.primaryPressed,
			releaseReason: releaseReason
		)
		CParsec.sendMouseClickMessage(
			.right,
			buttons.secondaryPressed,
			releaseReason: releaseReason
		)
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesBegan(touches, with: event)
		let hasIndirectPointer = touches.contains { $0.type == .indirectPointer }
		if hasIndirectPointer, let event {
			syncIndirectPointerButtons(buttonMask: event.buttonMask)
		}
	}

	// Indirect touches only sync buttons. Motion is owned elsewhere: absolute
	// drag by handleNativePointerDrag, captured (relative) motion solely by
	// GCMouse.mouseMovedHandler — sending deltas here too doubled drags.
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesMoved(touches, with: event)
		let hasIndirectPointer = touches.contains { $0.type == .indirectPointer }
		if hasIndirectPointer, let event {
			syncIndirectPointerButtons(buttonMask: event.buttonMask)
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesEnded(touches, with: event)
		let indirectTouches = touches.filter { $0.type == .indirectPointer }
		guard !indirectTouches.isEmpty else { return }

		if pointerBehavior.inputRoute == .absolute,
		   CParsec.mouseInputSnapshot.pressedCount > 0,
		   let finalTouch = indirectTouches.first {
			sendNativePointerPosition(finalTouch.preciseLocation(in: view))
		}
		syncIndirectPointerButtons(buttonMask: [])
		pointerDeltaAccumulator.reset()
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)
		guard touches.contains(where: { $0.type == .indirectPointer }) else { return }
		syncIndirectPointerButtons(
			buttonMask: [],
			releaseReason: .gestureCancelled
		)
		pointerDeltaAccumulator.reset()
	}


	// Move the local cursor overlay (no-op if it's hidden — we just keep
	// the tracker fresh so toggling the setting mid-session lands on a
	// sensible position).
	func moveLocalCursor(to position: CGPoint) {
		localCursorPosition = position
		clampAndApplyLocalCursor()
	}

	func moveLocalCursor(byX dx: CGFloat, y dy: CGFloat) {
		localCursorPosition.x += dx
		localCursorPosition.y += dy
		clampAndApplyLocalCursor()
	}

	var shouldForwardRemoteScroll: Bool {
		(scrollView?.zoomScale ?? 1.0) <= 1.0
	}

	private func clampAndApplyLocalCursor() {
		// Keep the local dot on the displayed image, not in the letterbox bars:
		// the host cursor it stands for is confined to the host screen.
		let bounds = ParsecResolution.aspectFit(
			CGSize(width: CGFloat(CParsec.hostWidth), height: CGFloat(CParsec.hostHeight)),
			in: contentView.bounds.size
		)
		localCursorPosition.x = max(bounds.minX, min(localCursorPosition.x, bounds.maxX))
		localCursorPosition.y = max(bounds.minY, min(localCursorPosition.y, bounds.maxY))
		localCursorImageView?.center = localCursorPosition
	}

	private func resetKeyboardBookkeeping() {
		heldModifierKeyCodes.removeAll()
		suppressedKeyUps.removeAll()
		chordArmed = false
		chordSawOtherKey = false
		resetKeyboardAccessoryToggles(in: keyboardAccessoriesView)
	}

	private func resetKeyboardAccessoryToggles(in view: UIView?) {
		guard let view else { return }
		if let button = view as? KeyboardButton, button.isToggleable {
			button.isOn = false
			button.backgroundColor = .black
		}
		for subview in view.subviews {
			resetKeyboardAccessoryToggles(in: subview)
		}
	}

	private func remoteKeyEvent(_ usage: UIKeyboardHIDUsage?, pressed: Bool) -> KeyBoardKeyEvent? {
		guard let usage else { return nil }
		return KeyBoardKeyEvent(
			key: RemoteKeyCode(
				rawValue: UInt32(KeyCodeTranslators.uiKeyCodeToInt(key: usage))
			),
			isPressBegin: pressed
		)
	}

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key else { continue }
			hardwareKeyBegan(key.keyCode, modifiers: key.modifierFlags)
		}
	}

	override func pressesEnded (_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key else { continue }
			hardwareKeyEnded(key.keyCode)
		}
	}

	// UIKey has no public initializer, so the per-key logic takes the HID
	// usage + modifier flags; tests drive the ` and ⌃⇧ macros through these.
	func hardwareKeyBegan(_ usage: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) {
		// Shortcut matrix evidence: which modifier chords iPadOS delivers.
		// Only usage codes of chords are logged, never typed text.
		// Modifier keys themselves (usage >= 224) are noise here.
		if usage.rawValue < 224, !modifiers.intersection([.command, .control, .alternate]).isEmpty {
			Diagnostics.note("key-chord via=uikit usage=\(usage.rawValue) mods=\(modifiers.rawValue)")
		}
		chordTrackPressBegan(usage)
		// Backtick→Cmd+Space remap: a bare ` becomes a manual language switch.
		// Swallow the grave key-down and synthesize Cmd+Space at the host;
		// record the suppression so the matching key-up is swallowed too.
		if backtickWillEmulateCmdSpace(usage, modifiers: modifiers) {
			// Auto-repeat delivers repeated pressesBegan with no intervening
			// key-up; fire Cmd+Space only on the first down so holding ` does
			// not spam input-source switches at the host.
			if suppressedKeyUps.insert(usage).inserted {
				fireCmdSpace(source: "backtick")
			}
			return
		}
		// Always forward the raw scancode unchanged — the Cmd+Space emulation
		// is additive and fires only on a clean Ctrl+Shift release, so host
		// shortcuts like Ctrl+Shift+X keep working.
		if let keyEvent = remoteKeyEvent(usage, pressed: true) {
			CParsec.sendKeyboardMessage(event: keyEvent)
		}
	}

	func hardwareKeyEnded(_ usage: UIKeyboardHIDUsage) {
		// If we swallowed this key's key-down (backtick→Cmd+Space), swallow the
		// key-up too — the host already saw a complete Cmd+Space tap.
		if suppressedKeyUps.remove(usage) != nil {
			chordTrackPressEnded(usage)
			return
		}
		if let keyEvent = remoteKeyEvent(usage, pressed: false) {
			CParsec.sendKeyboardMessage(event: keyEvent)
		}
		chordTrackPressEnded(usage)
	}

	override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		super.pressesCancelled(presses, with: event)
		// A cancelled press never delivers pressesEnded, so its key-up would be
		// lost — both for the host (stuck modifier) and for our chord bookkeeping.
		for press in presses {
			if let usage = press.key?.keyCode, suppressedKeyUps.remove(usage) != nil {
				chordTrackPressEnded(usage)
				continue
			}
			if let keyEvent = remoteKeyEvent(press.key?.keyCode, pressed: false) {
				CParsec.sendKeyboardMessage(
					event: keyEvent,
					releaseReason: .cancelled
				)
			}
			chordTrackPressEnded(press.key?.keyCode)
		}
		// Any interruption invalidates an in-flight chord.
		chordArmed = false
		chordSawOtherKey = false
	}

	// True when the backtick→Cmd+Space remap should fire for this press: the
	// feature is enabled, the key is the grave/backtick, and NO Cmd/Ctrl/Alt/
	// Shift is held (so Shift+` = tilde and Cmd+` still reach the host as normal
	// keys). Caps Lock and other non-blocking flags are ignored.
	private func backtickWillEmulateCmdSpace(
		_ usage: UIKeyboardHIDUsage,
		modifiers: UIKeyModifierFlags
	) -> Bool {
		guard SettingsHandler.backtickEmulatesCmdSpace,
		      usage == .keyboardGraveAccentAndTilde else { return false }
		return modifiers.isDisjoint(with: [.command, .control, .alternate, .shift])
	}

	// MARK: Ctrl+Shift → Cmd+Space chord machine (S05)

	private func isModifierUsage(_ usage: UIKeyboardHIDUsage) -> Bool {
		switch usage {
		case .keyboardLeftControl, .keyboardRightControl,
		     .keyboardLeftShift, .keyboardRightShift,
		     .keyboardLeftAlt, .keyboardRightAlt,
		     .keyboardLeftGUI, .keyboardRightGUI:
			return true
		default:
			return false
		}
	}

	private func chordHasControl() -> Bool {
		return heldModifierKeyCodes.contains(.keyboardLeftControl)
			|| heldModifierKeyCodes.contains(.keyboardRightControl)
	}

	private func chordHasShift() -> Bool {
		return heldModifierKeyCodes.contains(.keyboardLeftShift)
			|| heldModifierKeyCodes.contains(.keyboardRightShift)
	}

	// Any modifier outside Ctrl/Shift (Alt or Cmd) disqualifies the chord — we
	// only want a *clean* Ctrl+Shift, not Ctrl+Shift+Alt etc.
	private func chordHasForeignModifier() -> Bool {
		return heldModifierKeyCodes.contains(.keyboardLeftAlt)
			|| heldModifierKeyCodes.contains(.keyboardRightAlt)
			|| heldModifierKeyCodes.contains(.keyboardLeftGUI)
			|| heldModifierKeyCodes.contains(.keyboardRightGUI)
	}

	private func chordTrackPressBegan(_ usage: UIKeyboardHIDUsage) {
		guard SettingsHandler.ctrlShiftEmulatesCmdSpace else { return }
		if isModifierUsage(usage) {
			heldModifierKeyCodes.insert(usage)
			// Arm only on a clean Ctrl+Shift with no foreign modifier.
			if chordHasControl() && chordHasShift() && !chordHasForeignModifier() {
				chordArmed = true
				chordSawOtherKey = false
			} else if chordHasForeignModifier() {
				// Alt/Cmd joined → this is a different combo, not our chord.
				chordSawOtherKey = true
			}
		} else {
			// A real key was pressed while modifiers are held → not a bare chord.
			chordSawOtherKey = true
		}
	}

	private func chordTrackPressEnded(_ usage: UIKeyboardHIDUsage?) {
		guard let usage else { return }
		guard SettingsHandler.ctrlShiftEmulatesCmdSpace else {
			// Setting may have flipped off mid-hold; keep the held-set honest.
			if isModifierUsage(usage) { heldModifierKeyCodes.remove(usage) }
			return
		}
		guard isModifierUsage(usage) else { return }

		let wasArmed = chordArmed
		let cleanRelease = !chordSawOtherKey
		// Fire when the last of the Ctrl/Shift pair lifts on a clean chord.
		let isCtrlOrShift = (usage == .keyboardLeftControl || usage == .keyboardRightControl
			|| usage == .keyboardLeftShift || usage == .keyboardRightShift)

		heldModifierKeyCodes.remove(usage)

		// Fire only once the pair has *fully* lifted (neither Ctrl nor Shift
		// still held). Keying on "not both-held" instead would fire on the
		// FIRST release while the other modifier is still down — so dropping
		// Ctrl to continue with Shift+<key> would spuriously emit Cmd+Space.
		if wasArmed && cleanRelease && isCtrlOrShift && !chordHasControl() && !chordHasShift() {
			fireCmdSpace(source: "ctrl-shift")
		}
		// Once neither Ctrl nor Shift remains, fully reset.
		if !chordHasControl() && !chordHasShift() {
			chordArmed = false
			chordSawOtherKey = false
		}
	}

	private func fireCmdSpace(source: String) {
		// iPadOS owns the physical Cmd+Space chord. The explicit host macro uses
		// the S08 state boundary and cannot leave a delayed modifier behind.
		sendHostLanguageSwitch(source: source) {
			CParsec.sendMacShortcut(.spotlightOrInputSource)
		}
	}

	private var lastHostLanguageSwitch: (at: CFTimeInterval, isSync: Bool)?

	/// Every host input-source toggle goes through here: Globe sync ("globe" =
	/// iPad input-mode change), ⌃⇧ and `. One physical action = one host toggle:
	/// a key macro and an iPad language change within 0.3 s of each other are
	/// the same keypress seen twice, so the second is dropped and the pair is
	/// consumed. Repeats of the same kind are deliberate and always sent (the
	/// old 0.8 s window dropped every other ⌃⇧ press when tapped ~1/s).
	func sendHostLanguageSwitch(source: String, send: () -> Void) {
		let now = CACurrentMediaTime()
		let isSync = source == "globe"
		let duplicate = Self.isSameLanguageSwitchAction(isSync: isSync, now: now, last: lastHostLanguageSwitch)
		let sinceMs = lastHostLanguageSwitch.map { Int((now - $0.at) * 1000) } ?? -1
		Diagnostics.note("layout-switch source=\(source) sent=\(!duplicate) sinceLastMs=\(sinceMs)")
		lastHostLanguageSwitch = duplicate ? nil : (now, isSync)
		guard !duplicate else { return }
		send()
	}

	/// True when this toggle is the other half of the previous one: one is a
	/// key macro, the other an iPad input-mode change, ≤ 0.3 s apart.
	static func isSameLanguageSwitchAction(
		isSync: Bool,
		now: CFTimeInterval,
		last: (at: CFTimeInterval, isSync: Bool)?
	) -> Bool {
		guard let last else { return false }
		return last.isSync != isSync && now - last.at < 0.3
	}
	
	@objc func keyboardWillShow(notification: NSNotification) {
		if let keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let height = keyboardFrame.height
			keyboardHeight = height
            keyboardVisible = true

            // Allow scrolling past current bottom to see hidden content
            scrollView.contentInset.bottom = height

            // Automatic scroll up only if mouse is in the bottom half of the screen
            let mouseY = CGFloat(CParsec.mouseInfo.mouseY)
            let screenMidY = view.bounds.height / 2.1

            if mouseY > screenMidY {
                 let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + height)
                 let newOffsetY = min(maxOffsetY, scrollView.contentOffset.y + height / 1.25)

                 scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffsetY), animated: true)
				
            }
		}
		onKeyboardVisibilityChanged?(true)
	}

	@objc func keyboardWillHide(notification: NSNotification) {
		CParsec.releaseAllKeyboardKeys(reason: .focusLost)
		resetKeyboardBookkeeping()
		keyboardHeight = 0.0
        keyboardVisible = false
        
        // Restore inset
        scrollView.contentInset.bottom = 0
        
        // Transform cleanup (just in case)
        view.transform = .identity
        
        // Automatic scroll down in landscape mode (reverse of show)
        if view.bounds.width > view.bounds.height {
             // We subtract, but clamp to 0 (or valid range)
			let newOffsetY = max(0, scrollView.contentOffset.y - ((notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height ?? 0.0))
             // Or maybe just clamp to valid range without forcing a subtract?
             // User said "bajar la altura", implying a reverse scroll.
             scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffsetY), animated: true)
        }
		onKeyboardVisibilityChanged?(false)

		// Reclaim first responder for the hidden language-sync field after ANY
		// soft-keyboard dismissal. Previously only setKeyboardVisible(false)
		// reclaimed it, so dismissing via the toolbar Done button, a swipe-down,
		// the Globe key, or any system-driven hide left the hidden field resigned
		// — at which point currentInputModeDidChangeNotification stops firing and
		// keyboard-layout sync silently dies until the next setKeyboardVisible(false).
		// keyboardWillHide is the common funnel for every dismiss path, so reclaim
		// here. Deferred to the next runloop tick so we don't fight the in-progress
		// hide; guarded on !keyboardVisible so a show that raced in keeps the VC as
		// first responder. The field has an empty inputView, so this never re-shows
		// the keyboard.
		DispatchQueue.main.async { [weak self] in
			guard let self = self, !self.keyboardVisible else { return }
			self.languageSync?.reclaimFirstResponder()
		}
	}

}

extension ParsecViewController : UIGestureRecognizerDelegate {

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		return true
	}

	// The tap waits for the long-press to fail; outside touchpad mode the
	// long-press does nothing, so it must not begin (a slow tap would click nothing).
	func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		if gestureRecognizer is UILongPressGestureRecognizer {
			return SettingsHandler.cursorMode == .touchpad
		}
		return true
	}

	@objc func handlePinchGesture(_ gestureRecognizer: UIPinchGestureRecognizer) {
		// Pinch is handled by UIScrollView
	}

	@objc func handlePanGesture(_ gestureRecognizer: UIPanGestureRecognizer)
	{
		// Any new direct-touch interaction means the user has taken control back
		// from a client-generated momentum tail.
		if ParsecTouchInteractionPolicy.shouldInterruptScrollMomentum(
			for: gestureRecognizer.state
		) {
			stopScrollMomentum()
		}

		//		print("number = \(gestureRecognizer.numberOfTouches) status = \(gestureRecognizer.state.rawValue)")
		// lock activatedPanFingerNumber in case user not releasing both finger at the same time
		// Key cleanup on the terminal state, not touch count: a cancel/fail can
		// still report touches, which used to leave the direct-mode left button held.
		let panFinished = [.ended, .cancelled, .failed].contains(gestureRecognizer.state)
		if panFinished || gestureRecognizer.numberOfTouches == 0 {
			if panFinished {
				if activatedPanFingerNumber == 2 {
					touchScrollAccumulator.reset()
					lastTouchScrollTranslation = .zero
				}
				activatedPanFingerNumber = 0
				pointerDeltaAccumulator.reset()
				lastPanTranslation = .zero

				if SettingsHandler.cursorMode == .direct {
					let button = RemoteMouseButton.init(rawValue: 1)
					CParsec.sendMouseClickMessage(
						button,
						false,
						releaseReason: gestureRecognizer.state == .ended
							? .normal
							: .gestureCancelled
					)
				}
			}
		} else if activatedPanFingerNumber == 2 || (gestureRecognizer.numberOfTouches == 2 && activatedPanFingerNumber == 0) {
			// Lock the two-finger mode first so a zoomed pan never falls
			// through to one-finger mouse motion when a finger lifts.
			activatedPanFingerNumber = 2
			// While actually zoomed, UIScrollView exclusively consumes the
			// two-finger pan (zoom setting on at 1.0x still forwards).
			guard shouldForwardRemoteScroll else {
				// Keep the anchor fresh so un-zooming mid-gesture can't jump.
				lastTouchScrollTranslation = gestureRecognizer.translation(in: gestureRecognizer.view)
				return
			}
			let translation = gestureRecognizer.translation(in: gestureRecognizer.view)
			if gestureRecognizer.state == .began {
				lastTouchScrollTranslation = .zero
				touchScrollAccumulator.reset()
			}
			let transformed = ParsecPointerTransform.scroll(
				x: Double(translation.x - lastTouchScrollTranslation.x),
				y: Double(translation.y - lastTouchScrollTranslation.y),
				sensitivity: SettingsHandler.scrollSensitivity,
				natural: SettingsHandler.naturalScrolling
			)
			lastTouchScrollTranslation = translation
			if let whole = touchScrollAccumulator.consume(transformed) {
				CParsec.sendWheelMsg(x: whole.x, y: whole.y)
			}
		} else if activatedPanFingerNumber == 1 || (gestureRecognizer.numberOfTouches == 1 && activatedPanFingerNumber == 0) {
			activatedPanFingerNumber = 1
			// move mouse
			if SettingsHandler.cursorMode == .direct {
                // Map screen tap to content coordinates
				let position = gestureRecognizer.location(in: gestureRecognizer.view)
                // Convert to content coordinates
				let adjustedPosition = contentView.convert(position, from: view)
				// Clamped to the content (finite, in range) before the Int32 conversion.
				let px = adjustedPosition.x.isFinite ? min(max(adjustedPosition.x, 0), contentView.bounds.width) : 0
				let py = adjustedPosition.y.isFinite ? min(max(adjustedPosition.y, 0), contentView.bounds.height) : 0
				CParsec.sendMousePosition(Int32(px), Int32(py))
				moveLocalCursor(to: adjustedPosition)
			} else {
				// Simple translation-based movement with sub-pixel accumulation
				let currentTranslation = gestureRecognizer.translation(in: gestureRecognizer.view)

				if gestureRecognizer.state == .began {
					lastPanTranslation = .zero
					pointerDeltaAccumulator.reset()
				}

				let transformed = ParsecPointerTransform.movement(
					x: Double(currentTranslation.x - lastPanTranslation.x),
					y: Double(currentTranslation.y - lastPanTranslation.y),
					sensitivity: SettingsHandler.mouseSensitivity,
					acceleration: SettingsHandler.mouseAcceleration
				)
				lastPanTranslation = currentTranslation
				moveLocalCursor(
					byX: CGFloat(transformed.x),
					y: CGFloat(transformed.y)
				)
				if let whole = pointerDeltaAccumulator.consume(transformed) {
					CParsec.sendMouseDelta(whole.x, whole.y)
				}
			}

			if gestureRecognizer.state == .began && SettingsHandler.cursorMode == .direct {
				let button = RemoteMouseButton.init(rawValue: 1)
				CParsec.sendMouseClickMessage(button, true)
			}

		}
	}
	
	// Trackpad / mouse-wheel scroll handler, separated from handlePanGesture so it
	// can use translation deltas (smooth) instead of velocity (rough wheel
	// messages). Hooked up by a UIPanGestureRecognizer with
	// allowedScrollTypesMask = .all and maximumNumberOfTouches = 0 in viewDidLoad,
	// so it only sees scroll-wheel / trackpad-scroll events, never finger touches.
	@objc func handleTrackpadScroll(_ gestureRecognizer: UIPanGestureRecognizer) {
		// "Natural scrolling" toggle ON = swipe-direction follows content, which
		// is the macOS default ("Natural" in System Settings). With the user's
		// Mac on its default Natural Scrolling = ON, we want to forward
		// translation deltas without flipping — host applies its own
		// inversion. Flip only when toggle is OFF (= user wants classic
		// mouse-wheel feel).
		// Some Magic Keyboard sequences resume at `.changed` without exposing a
		// fresh `.began`; stop the old glide before any live delta in either case.
		if ParsecTouchInteractionPolicy.shouldInterruptTrackpadMomentum(
			for: gestureRecognizer.state
		) {
			stopScrollMomentum()
		}
		// Captured (pointer-locked) mode: GCMouse scroll owns the wheel, so this
		// recognizer must not send too (GamepadController.sendMouseScroll).
		guard pointerBehavior.inputRoute == .absolute else { return }

		switch gestureRecognizer.state {
		case .began:
			// Reset live-scroll anchors for the new gesture.
			lastScrollTranslation = .zero
			trackpadScrollAccumulator.reset()
			peakScrollVelocityX = 0
			peakScrollVelocityY = 0
			trackpadScrollTravel = 0
		case .changed:
			let translation = gestureRecognizer.translation(in: gestureRecognizer.view)
			// When the user is zoomed in, let UIScrollView's own pan handle the
			// scroll locally — otherwise we'd both scroll the local view AND
			// send wheel messages to the host (double-pan). Keep
			// lastScrollTranslation in sync before returning (SC5): otherwise
			// the next forwarded `.changed` after un-zoom computes a delta
			// against a stale anchor and jumps the host.
			if scrollView.zoomScale > 1.0 {
				lastScrollTranslation = translation
				return
			}

			let deltaX = translation.x - lastScrollTranslation.x
			let deltaY = translation.y - lastScrollTranslation.y
			trackpadScrollTravel += hypot(deltaX, deltaY)
			let transformed = ParsecPointerTransform.scroll(
				x: Double(deltaX),
				y: Double(deltaY),
				sensitivity: SettingsHandler.scrollSensitivity,
				natural: SettingsHandler.naturalScrolling
			)
			lastScrollTranslation = translation

			// Track the peak velocity over the gesture. `velocity(in:)` at
			// `.ended` is already near-zero because iPadOS pre-decelerates its
			// scroll-event stream, so we seed the post-lift glide from the peak
			// seen mid-gesture instead.
			let v = gestureRecognizer.velocity(in: gestureRecognizer.view)
			let peak = ParsecScrollMomentumPolicy.peakVelocity(
				current: ParsecInputDelta(
					x: Double(peakScrollVelocityX),
					y: Double(peakScrollVelocityY)
				),
				candidate: ParsecInputDelta(x: Double(v.x), y: Double(v.y))
			)
			peakScrollVelocityX = CGFloat(peak.x)
			peakScrollVelocityY = CGFloat(peak.y)

			if let whole = trackpadScrollAccumulator.consume(transformed) {
				CParsec.sendWheelMsg(x: whole.x, y: whole.y)
				scrollLiveUnits += abs(Int(whole.x)) + abs(Int(whole.y))
			}
		case .ended:
			// Seed a decaying glide from the peak velocity (scaled the same way
			// the live deltas were). The accumulator carries over so sub-pixel
			// remainder isn't lost between the live phase and the glide.
			lastScrollTranslation = .zero
			if scrollView.zoomScale <= 1.0 {
				let seed = ParsecScrollMomentumPolicy.glideSeed(ParsecInputDelta(
					x: Double(peakScrollVelocityX),
					y: Double(peakScrollVelocityY)
				))
				let velocity = ParsecPointerTransform.scroll(
					x: seed.x,
					y: seed.y,
					sensitivity: SettingsHandler.scrollSensitivity,
					natural: SettingsHandler.naturalScrolling
				)
				// Decide on the unscaled speed so Scroll Sensitivity changes
				// distance only, not whether a release glides.
				let peakSpeed = hypot(seed.x, seed.y)
				Diagnostics.note(
					"scroll-gesture travel=\(Int(trackpadScrollTravel)) liveUnits=\(scrollLiveUnits) " +
					"peak=\(Int(hypot(peakScrollVelocityX, peakScrollVelocityY))) seed=\(Int(peakSpeed)) " +
					"sens=\(SettingsHandler.scrollSensitivity) natural=\(SettingsHandler.naturalScrolling)"
				)
				scrollLiveUnits = 0
				if ParsecScrollMomentumPolicy.shouldStart(
					travel: Double(trackpadScrollTravel),
					peakSpeed: peakSpeed
				) {
					startScrollMomentum(
						velX: Float(velocity.x),
						velY: Float(velocity.y)
					)
				} else {
					stopScrollMomentum()
				}
			}
			peakScrollVelocityX = 0
			peakScrollVelocityY = 0
			trackpadScrollTravel = 0
		case .cancelled, .failed:
			stopScrollMomentum()
			lastScrollTranslation = .zero
			trackpadScrollAccumulator.reset()
			peakScrollVelocityX = 0
			peakScrollVelocityY = 0
			trackpadScrollTravel = 0
		default:
			break
		}
	}

	// MARK: - Trackpad scroll momentum (client-side inertia)

	private func startScrollMomentum(velX: Float, velY: Float) {
		stopScrollMomentum()
		let maximumDuration = ParsecScrollMomentumPolicy.clampedDuration(
			SettingsHandler.scrollGlideDuration
		)
		guard ParsecScrollMomentumPolicy.shouldContinue(
			elapsed: 0,
			maximumDuration: maximumDuration
		) else {
			return
		}
		momentumElapsed = 0
		momentumVelocityX = velX
		momentumVelocityY = velY
		let link = CADisplayLink(target: self, selector: #selector(stepScrollMomentum(_:)))
		link.add(to: .main, forMode: .common)
		momentumDisplayLink = link
	}

	@objc private func stepScrollMomentum(_ link: CADisplayLink) {
		// dt is the real duration of the upcoming frame, so the glide travels the
		// same distance per second at 60 Hz and 120 Hz (the bug that doubled the
		// old hardcoded `peak/60` seed on the 120 Hz iPad). Clamp out the absurd
		// first-tick / stall values.
		let dt = Float(link.targetTimestamp - link.timestamp)
		guard dt > 0, dt < 0.1 else { return }
		momentumElapsed += TimeInterval(dt)
		guard ParsecScrollMomentumPolicy.shouldContinue(
			elapsed: momentumElapsed,
			maximumDuration: ParsecScrollMomentumPolicy.clampedDuration(
				SettingsHandler.scrollGlideDuration
			)
		) else {
			stopScrollMomentum()
			return
		}

		if let whole = trackpadScrollAccumulator.consume(
			ParsecInputDelta(
				x: Double(momentumVelocityX * dt),
				y: Double(momentumVelocityY * dt)
			)
		) {
			CParsec.sendWheelMsg(x: whole.x, y: whole.y)
			scrollGlideUnits += abs(Int(whole.x)) + abs(Int(whole.y))
		}

		let decay = powf(scrollMomentumDecayPerSecond, dt)
		momentumVelocityX *= decay
		momentumVelocityY *= decay
		if hypotf(momentumVelocityX, momentumVelocityY) < scrollMomentumStopSpeed {
			stopScrollMomentum()
		}
	}

	private func stopScrollMomentum() {
		if momentumDisplayLink != nil {
			Diagnostics.note("scroll-glide units=\(scrollGlideUnits) elapsed=\(String(format: "%.2f", momentumElapsed))")
		}
		scrollGlideUnits = 0
		momentumDisplayLink?.invalidate()
		momentumDisplayLink = nil
		momentumVelocityX = 0
		momentumVelocityY = 0
		momentumElapsed = 0
	}

	@objc func handleSingleFingerTap(_ gestureRecognizer: UITapGestureRecognizer) {

		let location = gestureRecognizer.location(in:gestureRecognizer.view)
		let adjustedLocation = contentView.convert(location, from: view)
		touchController.onTap(typeOfTap: 1, location: adjustedLocation)
	}
	
	@objc func handleTwoFingerTap(_ gestureRecognizer: UITapGestureRecognizer) {
		
		let location : CGPoint;
		switch SettingsHandler.rightClickPosition {
		case .firstFinger:
			location = gestureRecognizer.location(ofTouch: 0, in: gestureRecognizer.view)
			break;
		case .secondFinger:
			location = gestureRecognizer.location(ofTouch: 1, in: gestureRecognizer.view)
			break
		default:
			location = gestureRecognizer.location(in: gestureRecognizer.view)
		}

		let adjustedLocation = contentView.convert(location, from: view)
		touchController.onTap(typeOfTap: 3, location: adjustedLocation)
	}
	
	@objc func handleThreeFinderTap(_ gestureRecognizer: UITapGestureRecognizer) {
		showKeyboard()
	}
	
	@objc func handleLongPress(_ gestureRecognizer: UIGestureRecognizer) {
		if SettingsHandler.cursorMode != .touchpad {
			return
		}
		let button = RemoteMouseButton.init(rawValue: 1)

		if gestureRecognizer.state == .began{
			CParsec.sendMouseClickMessage(button, true)
		} else if gestureRecognizer.state == .ended {
			CParsec.sendMouseClickMessage(button, false)
		} else if gestureRecognizer.state == .cancelled || gestureRecognizer.state == .failed {
			CParsec.sendMouseClickMessage(
				button,
				false,
				releaseReason: .gestureCancelled
			)
		} else if gestureRecognizer.state == .changed {
			// The simultaneous one-finger pan recognizer exclusively owns movement
			// and applies the shared transform/accumulator. Long press owns only
			// the left-button latch, avoiding duplicate deltas during drag.
			return
		}
	}
	
    // UIScrollViewDelegate
	func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
		// UIScrollView can own a two-finger pan independently of the main direct-
		// touch recognizer, especially while transitioning into or out of zoom.
		// Either route must stop a host-scroll momentum tail immediately.
		stopScrollMomentum()
	}

	func viewForZooming(in scrollView: UIScrollView) -> UIView? {
		return contentView
	}

	func scrollViewDidZoom(_ scrollView: UIScrollView) {
		// Update isPinching if needed, or other logic
	}
	
	func setZoomEnabled(_ enabled: Bool) {
		zoomEnabled = enabled
		scrollView.pinchGestureRecognizer?.isEnabled = enabled
	}
	
}
	
extension ParsecViewController : UIPointerInteractionDelegate {
	func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
		pointerBehavior.prefersPointerLocked ? UIPointerStyle.hidden() : nil
	}


	func pointerInteraction(_ inter: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
		let loc = request.location
		if let iv = view!.hitTest(loc, with: nil) {
			let rect = view!.convert(iv.bounds, from: iv)
			let region = UIPointerRegion(rect: rect, identifier: iv.tag)
			return region
		}
		return nil
	}
	
}

class KeyboardButton: UIButton {
	let keyText: String
	let isToggleable: Bool
	var isOn = false
	
	required init(keyText: String, isToggleable: Bool) {
		self.keyText = keyText
		self.isToggleable = isToggleable
		super.init(frame: .zero)
		addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
		addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchDragExit, .touchCancel])
			
	}
	
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
	
	// Add a press-down animation for feedback
	@objc private func handleTouchDown() {
		self.alpha = 0.5
	}
	
	// Restore to normal state when touch ends
	@objc private func handleTouchUp() {
		UIView.animate(withDuration: 0.2) {
			self.alpha = 1.0
		}
	}
}

// MARK: - Virtual Keyboard
extension ParsecViewController : UIKeyInput, UITextInputTraits {
	var hasText: Bool {
		return true
	}
	
	var keyboardType: UIKeyboardType {
		get {
			return .asciiCapable
		}
		set {
			
		}
	}
	
	override var canBecomeFirstResponder: Bool {
		return true
	}

	func insertText(_ text: String) {
		// Per character: typed/pasted "F5" or "TAB" must not become that key.
		text.forEach { CParsec.sendVirtualKeyboardInput(text: String($0)) }
	}

	func deleteBackward() {
		CParsec.sendVirtualKeyboardInput(text: "BACKSPACE")
	}
	
    // copied from moonlight https://github.com/moonlight-stream/moonlight-ios/blob/022352c1667788d8626b659d984a290aa5c25e17/Limelight/Input/StreamView.m#L393
	override var inputAccessoryView: UIView? {

		if let keyboardAccessoriesView {
			return keyboardAccessoriesView
		}
        // Refactored to UIView with autoresizing mask for better landscape support
        // Using frame-based layout for the container to avoid constraint conflicts with keyboard
		let containerView = UIView(frame: CGRect(x: 0, y: 0, width: self.view.bounds.width, height: 94))
        containerView.autoresizingMask = [.flexibleWidth]
        containerView.backgroundColor = .clear

		// Use a simple UIView instead of UIToolbar to avoid constraint conflicts
		let toolbarBackground = UIView(frame: CGRect(x: 0, y: 50, width: containerView.bounds.width, height: 44))
		toolbarBackground.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
		toolbarBackground.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)

		let scrollView = UIScrollView(frame: CGRect(x: 8, y: 0, width: toolbarBackground.bounds.width - 80, height: 44))
		scrollView.autoresizingMask = [.flexibleWidth]
		scrollView.showsHorizontalScrollIndicator = false

		let buttonStackView = UIStackView()
		buttonStackView.axis = .horizontal
		buttonStackView.distribution = .equalSpacing
		buttonStackView.alignment = .center
		buttonStackView.spacing = 8
		buttonStackView.translatesAutoresizingMaskIntoConstraints = false

		let shiftBarButton = createKeyboardButton(displayText: "⇧", keyText: "SHIFT", isToggleable: true)
		let windowsBarButton = createKeyboardButton(displayText: "⌘", keyText: "LGUI", isToggleable: true)
		let tabBarButton = createKeyboardButton(displayText: "⇥", keyText: "TAB", isToggleable: false)
		let escapeBarButton = createKeyboardButton(displayText: "⎋", keyText: "UIKeyInputEscape", isToggleable: false)
		let controlBarButton = createKeyboardButton(displayText: "⌃", keyText: "CONTROL", isToggleable: true)
		let altBarButton = createKeyboardButton(displayText: "⌥", keyText: "LALT", isToggleable: true)
		let deleteBarButton = createKeyboardButton(displayText: "Del", keyText: "DELETE", isToggleable: false)
		let f1Button = createKeyboardButton(displayText: "F1", keyText: "F1", isToggleable: false)
		let f2Button = createKeyboardButton(displayText: "F2", keyText: "F2", isToggleable: false)
		let f3Button = createKeyboardButton(displayText: "F3", keyText: "F3", isToggleable: false)
		let f4Button = createKeyboardButton(displayText: "F4", keyText: "F4", isToggleable: false)
		let f5Button = createKeyboardButton(displayText: "F5", keyText: "F5", isToggleable: false)
		let f6Button = createKeyboardButton(displayText: "F6", keyText: "F6", isToggleable: false)
		let f7Button = createKeyboardButton(displayText: "F7", keyText: "F7", isToggleable: false)
		let f8Button = createKeyboardButton(displayText: "F8", keyText: "F8", isToggleable: false)
		let f9Button = createKeyboardButton(displayText: "F9", keyText: "F9", isToggleable: false)
		let f10Button = createKeyboardButton(displayText: "F10", keyText: "F10", isToggleable: false)
		let f11Button = createKeyboardButton(displayText: "F11", keyText: "F11", isToggleable: false)
		let f12Button = createKeyboardButton(displayText: "F12", keyText: "F12", isToggleable: false)
		let upButton = createKeyboardButton(displayText: "↑", keyText: "UP", isToggleable: false)
		let downButton = createKeyboardButton(displayText: "↓", keyText: "DOWN", isToggleable: false)
		let leftButton = createKeyboardButton(displayText: "←", keyText: "LEFT", isToggleable: false)
		let rightButton = createKeyboardButton(displayText: "→", keyText: "RIGHT", isToggleable: false)
		let appSwitcherButton = createKeyboardButton(displayText: "⌘⇥", keyText: "MAC_APP_SWITCHER", isToggleable: false)
		let inputSourceButton = createKeyboardButton(displayText: "⌘␣", keyText: "MAC_INPUT_SOURCE", isToggleable: false)
		let closeWindowButton = createKeyboardButton(displayText: "⌘W", keyText: "MAC_CLOSE_WINDOW", isToggleable: false)
		let forceQuitButton = createKeyboardButton(displayText: "⌘⌥⎋", keyText: "MAC_FORCE_QUIT", isToggleable: false)
		let windowsAltTabButton = createKeyboardButton(displayText: "Alt⇥", keyText: "WIN_ALT_TAB", isToggleable: false)
		let windowsStartButton = createKeyboardButton(displayText: "Win", keyText: "WIN_START", isToggleable: false)
		let windowsLockButton = createKeyboardButton(displayText: "Win L", keyText: "WIN_LOCK", isToggleable: false)
		let windowsTaskManagerButton = createKeyboardButton(displayText: "Ctrl⇧⎋", keyText: "WIN_TASK_MANAGER", isToggleable: false)
		let windowsLayoutButton = createKeyboardButton(displayText: "Alt⇧", keyText: "WIN_LAYOUT", isToggleable: false)

		var buttons = [tabBarButton, shiftBarButton, controlBarButton, altBarButton, windowsBarButton, escapeBarButton, f1Button, f2Button, f3Button, f4Button, f5Button, f6Button, f7Button, f8Button, f9Button, f10Button, f11Button, f12Button, deleteBarButton, upButton, downButton, leftButton, rightButton]
		let shortcutVisibility = ParsecHostShortcutToolbarPolicy.visibility(
			mode: SettingsHandler.hostShortcutToolbarMode,
			host: CParsec.hostOS
		)
		if shortcutVisibility.showMac {
			buttons.insert(
				contentsOf: [appSwitcherButton, inputSourceButton, closeWindowButton, forceQuitButton],
				at: 0
			)
		}
		if shortcutVisibility.showWindows {
			buttons.insert(
				contentsOf: [windowsAltTabButton, windowsStartButton, windowsLockButton, windowsTaskManagerButton, windowsLayoutButton],
				at: 0
			)
		}

		for button in buttons {
			buttonStackView.addArrangedSubview(button)
		}

		scrollView.addSubview(buttonStackView)

		// Set constraints for the stack view inside the scroll view
		NSLayoutConstraint.activate([
			buttonStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
			buttonStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
			buttonStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
			buttonStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
			buttonStackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
		])

		// Done button with frame-based layout
		let doneButton = UIButton(type: .system)
		doneButton.frame = CGRect(x: toolbarBackground.bounds.width - 70, y: 0, width: 60, height: 44)
		doneButton.autoresizingMask = [.flexibleLeftMargin]
		doneButton.setTitle("Done", for: .normal)
		doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

		toolbarBackground.addSubview(scrollView)
		toolbarBackground.addSubview(doneButton)

		containerView.addSubview(toolbarBackground)

		keyboardAccessoriesView = containerView
		return containerView
	}
	
	func createKeyboardButton(displayText: String, keyText: String, isToggleable: Bool) -> UIButton {
		let button = KeyboardButton(keyText: keyText, isToggleable: isToggleable)
		
		// Set the image and button properties
		button.setTitle(displayText, for: .normal)
		button.titleLabel?.font = UIFont(name: "System", size: 10.0)
		button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
		button.titleLabel?.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
		if let label = button.titleLabel {
			label.textAlignment = .center
		}
		button.backgroundColor = .black
		button.layer.cornerRadius = 3.0
		
		button.titleLabel?.contentMode = .scaleAspectFit

		// Set target and action for button
		button.addTarget(target, action: #selector(toolbarButtonClicked(_:)), for: .touchUpInside)
		
		return button
	}
	
	@objc func toolbarButtonClicked(_ sender: KeyboardButton) {
		if let action = windowsShortcutAction(for: sender.keyText) {
			CParsec.sendWindowsShortcut(action)
			return
		}
		if let action = macShortcutAction(for: sender.keyText) {
			CParsec.sendMacShortcut(action, route: .explicitMacro)
			return
		}
		let isToggleable = sender.isToggleable
		var isOn = sender.isOn

		if isToggleable {
			isOn.toggle()
			if isOn {
				sender.backgroundColor = .lightGray
			} else {
				sender.backgroundColor = .black
			}
		}

		sender.isOn = isOn
		let keyText = sender.keyText

		
		if isToggleable {
			if isOn {
				CParsec.sendVirtualKeyboardInput(text: keyText, isOn: true)
			} else {
				CParsec.sendVirtualKeyboardInput(text: keyText, isOn: false)
			}
		} else {
			CParsec.sendVirtualKeyboardInput(text: keyText)
		}
		
	}
	
	private func windowsShortcutAction(
		for keyText: String
	) -> ParsecWindowsShortcutAction? {
		switch keyText {
		case "WIN_ALT_TAB": return .appSwitcher
		case "WIN_START": return .startMenu
		case "WIN_LOCK": return .lockWorkstation
		case "WIN_TASK_MANAGER": return .taskManager
		case "WIN_LAYOUT": return .layoutSwitch
		default: return nil
		}
	}

	private func macShortcutAction(
		for keyText: String
	) -> ParsecMacShortcutAction? {
		switch keyText {
		case "MAC_APP_SWITCHER": return .appSwitcher
		case "MAC_INPUT_SOURCE": return .spotlightOrInputSource
		case "MAC_CLOSE_WINDOW": return .closeWindow
		case "MAC_FORCE_QUIT": return .forceQuit
		default: return nil
		}
	}

	@objc func doneTapped() {
		// Resign first responder to dismiss the keyboard
		resignFirstResponder()
	}
	
	@objc func showKeyboard() {
		// Yield FR to the VC so the soft keyboard can attach. Symmetric to the
		// path in setKeyboardVisible.
		languageSync?.yieldFirstResponder()
		becomeFirstResponder()
	}

	// CRITICAL: This is the robust way to show the keyboard.
    // 1. Dispatch async to ensure view is attached to window.
    // 2. call reloadInputViews() to ensure updated accessory view (especially for rotation).
    // 3. call becomeFirstResponder().
    // 4. Do NOT simplify this to a synchronous call, or it will fail in some race conditions.
	func setKeyboardVisible(_ visible: Bool) {
		keyboardVisible = visible
		if visible {
            DispatchQueue.main.async {
                self.reloadInputViews()
                // Cede first-responder so the soft keyboard can attach to the
                // view controller (the hidden language-sync field holds it
                // otherwise).
                self.languageSync?.yieldFirstResponder()
                let success = self.becomeFirstResponder()
                if !success {
                   // Fallback: try again? or just log (can't log).
                   // Maybe ensure user interaction is on on window?
                }
            }
		} else {
			resignFirstResponder()
			// Reclaim so we keep getting currentInputModeDidChangeNotification
			// while the soft keyboard is hidden.
			languageSync?.reclaimFirstResponder()
		}
	}

}

// MARK: - System-shortcut capture
//
// iPadOS shell normally swallows Cmd+letter combinations (and many Cmd+modifier
// chords) before they reach any app — that's why Cmd+A inside a Parsec session
// doesn't "select all" on the host, Cmd+S doesn't save, etc.
//
// Registering an explicit UIKeyCommand for each combination tells the responder
// chain to deliver them to us instead. On iOS 15+, setting
// `wantsPriorityOverSystemBehavior = true` further suppresses the system's own
// text-input handling for the same chord.
//
// What we CANNOT capture on iPadOS via public APIs (no app can):
//   • Cmd+Space (Spotlight)
//   • Cmd+H (Home)
//   • Cmd+Tab (app switcher)
//   • Globe key shortcut layer
//   • Swipe-up-from-bottom (Home gesture)
//
// Those are wired below the responder chain in SpringBoard. The PR #64
// approach (remap Opt → Cmd on the host) is the workaround the iPad
// ecosystem has settled on for the most common case; we don't duplicate it
// here because that PR is in flight.
extension ParsecViewController {
	// Cached because keyCommands is queried each event and we register ~280
	// commands. Rebuilds itself the first time captureSystemKeys flips on
	// during a session and the user re-enters the streaming view.
	private static let _capturableCharset: String = "abcdefghijklmnopqrstuvwxyz0123456789-=[];',./`\\"
	// Command-only: registering plain Option chords turned held Option+key
	// into instant taps (key repeat / hold semantics lost on the host).
	static let _capturableModifierCombos: [UIKeyModifierFlags] = [
		.command,
		[.command, .shift],
		[.command, .alternate],
		[.command, .control]
	]

	// iOS queries `keyCommands` on every key event and on every first-responder
	// change. Rebuilding 286 UIKeyCommand objects each time would jank typing
	// on older iPads. Cache once per type (UIKeyCommand objects are stateless
	// modulo their action selector, so sharing across instances is safe — the
	// system dispatches the action to whichever responder is first).
	// If `captureSystemKeys` flips at runtime the user has to leave + re-enter
	// the streaming view to pick up the change.
	private static var _cachedKeyCommands: [UIKeyCommand]?

	func buildSystemCaptureKeyCommands() -> [UIKeyCommand] {
		if let cached = Self._cachedKeyCommands {
			return cached
		}
		var commands: [UIKeyCommand] = []
		for char in Self._capturableCharset {
			for mods in Self._capturableModifierCombos {
				let cmd = UIKeyCommand(
					input: String(char),
					modifierFlags: mods,
					action: #selector(handleCapturedKey(_:))
				)
				if #available(iOS 15.0, *) {
					cmd.wantsPriorityOverSystemBehavior = true
				}
				commands.append(cmd)
			}
		}
		// Cmd + special keys. Cmd+Space is registered but iPadOS still wins;
		// the host won't see it. Leaving it in so behaviour matches if Apple
		// ever loosens this.
		for special in ["\t", " ", "\r", "`"] {
			let cmd = UIKeyCommand(
				input: special,
				modifierFlags: .command,
				action: #selector(handleCapturedKey(_:))
			)
			if #available(iOS 15.0, *) {
				cmd.wantsPriorityOverSystemBehavior = true
			}
			commands.append(cmd)
		}
		Self._cachedKeyCommands = commands
		return commands
	}

	override var keyCommands: [UIKeyCommand]? {
		guard SettingsHandler.captureSystemKeys else { return super.keyCommands }
		return buildSystemCaptureKeyCommands()
	}

	// Translates a UIKeyCommand into a modifier-aware scancode sequence for
	// the host. We deliberately use sendVirtualKeyboardInput(text:, isOn:)
	// instead of (text:) so the wrapper doesn't auto-add Shift — we're
	// managing modifiers explicitly.
	@objc func handleCapturedKey(_ cmd: UIKeyCommand) {
		let mods = cmd.modifierFlags
		guard let raw = cmd.input, !raw.isEmpty else { return }
		Diagnostics.note("key-chord via=keycommand input=\(raw.unicodeScalars.map { $0.value }) mods=\(mods.rawValue)")

		if mods.contains(.command), raw == "\t" {
			CParsec.sendMacShortcut(.appSwitcher)
			return
		}
		if mods.contains(.command), raw == " " {
			CParsec.sendMacShortcut(.spotlightOrInputSource)
			return
		}

		let keyText: String
		switch raw {
		case "\t": keyText = "TAB"
		case " ": keyText = "SPACE"
		case "\r", "\n": keyText = "ENTER"
		default: keyText = raw.uppercased()
		}
		// Punctuation (⌘- ⌘= ⌘[ ⌘/ ⌘` …) has no key name: use the character table.
		let charCode = KeyCodeTranslators.getRemoteKeyCode(for: raw).remoteKeyCode
		guard let key = KeyCodeTranslators.parsecKeyCodeTranslator(keyText)
			?? (charCode > 0 ? RemoteKeyCode(rawValue: UInt32(charCode)) : nil) else { return }

		var chord: [RemoteKeyCode] = []
		if mods.contains(.command),
		   let modifier = KeyCodeTranslators.parsecKeyCodeTranslator("LGUI") {
			chord.append(modifier)
		}
		if mods.contains(.shift),
		   let modifier = KeyCodeTranslators.parsecKeyCodeTranslator("SHIFT") {
			chord.append(modifier)
		}
		if mods.contains(.control),
		   let modifier = KeyCodeTranslators.parsecKeyCodeTranslator("CONTROL") {
			chord.append(modifier)
		}
		if mods.contains(.alternate),
		   let modifier = KeyCodeTranslators.parsecKeyCodeTranslator("LALT") {
			chord.append(modifier)
		}
		chord.append(key)
		CParsec.sendKeyboardChord(chord, route: .priorityCapture)
	}
}

// MARK: - Language sync (Mac ↔ iPad keyboard layout)
//
// Goal: when the user switches the iPad's hardware-keyboard input language
// (Caps Lock toggle on Magic Keyboard / Ctrl+Space / Globe key), fire a hotkey
// at the host so its input source switches in lock-step.
//
// Why a hotkey and not a "real" Unicode-text path: Parsec's iOS SDK only sends
// MESSAGE_KEYBOARD with HID scancodes (see ParsecSDKBridge.sendKeyboardMessage).
// There is no documented MESSAGE_CHAR / UTF-8 path that would let us bypass
// the host layout. So we ask the host to switch its own layout. Default
// hotkey is Ctrl+Space (macOS built-in "select previous input source"); user
// can pick something else if their host config differs.
//
// Detecting the language change requires a UIResponder that accepts text
// input to be first responder (Apple's `currentInputModeDidChangeNotification`
// only fires in that case). We use a 1×1 alpha-0 UITextField with an empty
// inputView so the soft keyboard never appears; the field forwards
// pressesBegan/Ended to the view controller so hardware-keyboard scancodes
// continue to flow through the existing pipeline.
extension ParsecViewController {
	func startLanguageSyncIfNeeded() {
		// Always run: the hidden field is also what holds first responder so
		// hardware keys keep arriving. The setting only gates the hotkey.
		guard languageSync == nil else { return }
		let coordinator = LanguageSyncCoordinator(host: self, keyForwardTarget: self)
		coordinator.onLanguageChange = { [weak self] language in
			Diagnostics.note("layout-sync event=change lang=\(language ?? "nil") enabled=\(SettingsHandler.syncKeyboardLayout) hotkey=\(SettingsHandler.layoutSyncHotkey)")
			guard SettingsHandler.syncKeyboardLayout, let self else { return }
			self.sendHostLanguageSwitch(source: "globe") { self.sendLayoutSyncHotkey() }
		}
		coordinator.start()
		languageSync = coordinator
	}

	func stopLanguageSync() {
		languageSync?.stop()
		languageSync = nil
	}

	func sendLayoutSyncHotkey() {
		switch SettingsHandler.layoutSyncHotkey {
		case .none:
			return
		case .ctrlSpace:
			sendExplicitChord(["CONTROL", "SPACE"])
		case .cmdSpace:
			// ⌘Space on a Mac host, Win+Space (the layout switcher) on Windows.
			// Raw so the Windows "⌘ sends Ctrl" mode can't turn it into Ctrl+Space.
			sendExplicitChord(["LGUI", "SPACE"], mappingIntent: .raw)
		case .altSpace:
			sendExplicitChord(["LALT", "SPACE"])
		case .altShift:
			sendExplicitChord(["LALT", "SHIFT"])
		case .ctrlShift:
			sendExplicitChord(["CONTROL", "SHIFT"])
		}
	}

	private func sendExplicitChord(
		_ keyNames: [String],
		mappingIntent: ParsecKeyboardMappingIntent = .configured
	) {
		let chord = keyNames.compactMap {
			KeyCodeTranslators.parsecKeyCodeTranslator($0)
		}
		guard chord.count == keyNames.count else { return }
		CParsec.sendKeyboardChord(chord, route: .explicitMacro, mappingIntent: mappingIntent)
	}
}

// Hidden field that owns first-responder status so that
// UITextInputMode.currentInputModeDidChangeNotification keeps firing. It
// forwards all UIPress events to the host view controller without consuming
// them — that way hardware-keyboard scancodes continue to flow through
// ParsecViewController.pressesBegan/Ended unchanged.
final class LanguageSyncTextField: UITextField {
	weak var keyForwardTarget: UIResponder?

	override var canBecomeFirstResponder: Bool { return true }

	// Without a hardware keyboard, an empty inputView keeps the on-screen
	// keyboard from popping up. With one attached the soft keyboard never
	// shows anyway, and a custom inputView would hide the real input mode
	// (textInputMode → nil), so Globe switches could not be detected.
	private let _emptyInputView = UIView()
	override var inputView: UIView? {
		get { return GCKeyboard.coalesced == nil ? _emptyInputView : nil }
		set { /* ignore — we want the soft kb suppressed unconditionally */ }
	}

	// Critical: when this hidden field is first responder, iOS walks the
	// responder chain looking for an inputAccessoryView. The chain leads up
	// to ParsecViewController, which provides the OpenParsec keyboard
	// toolbar (⌘ ⌃ ⌥ ⇧ F1-F12 etc.). Result: the toolbar would appear on
	// every connection without any user action. Returning our own non-nil
	// (empty) accessory view halts the chain walk and keeps the toolbar
	// hidden until the user explicitly invokes showKeyboard().
	private let _emptyAccessoryView = UIView(frame: .zero)
	override var inputAccessoryView: UIView? {
		// Explicit getter + no-op setter because UIResponder.inputAccessoryView
		// is a mutable property — overriding with read-only fails compile.
		get { return _emptyAccessoryView }
		set { /* ignore */ }
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		// Suppress the iPad shortcuts bar (predictive text / cut/copy/paste
		// chevrons that hardware-keyboard text fields show by default).
		inputAssistantItem.leadingBarButtonGroups = []
		inputAssistantItem.trailingBarButtonGroups = []
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// By NOT calling super, we prevent UITextField's legacy text-input path
	// from consuming printable keys via UIKeyInput.insertText. Same trick
	// Moonlight uses in StreamView.m pressesBegan/pressesEnded.
	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		keyForwardTarget?.pressesBegan(presses, with: event)
	}
	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		keyForwardTarget?.pressesEnded(presses, with: event)
	}
	override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		keyForwardTarget?.pressesChanged(presses, with: event)
	}
	override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		keyForwardTarget?.pressesCancelled(presses, with: event)
	}
}

// Owns the hidden field, the change-notification observer, and the
// last-seen-language memo. Cooperates with the view controller's
// becomeFirstResponder / resignFirstResponder lifecycle via yield/reclaim.
final class LanguageSyncCoordinator {
	private weak var host: UIViewController?
	private weak var keyForwardTarget: UIResponder?
	private var hiddenField: LanguageSyncTextField?
	private var observer: NSObjectProtocol?
	private var lastLanguage: String?
	private var foregroundObserver: NSObjectProtocol?
	private var keyboardObservers: [NSObjectProtocol] = []
	// Debounce: rapid Caps-Lock taps can fire the notification twice on
	// some iPadOS versions, which would interleave modifier press/release
	// chords on the host. 150 ms is comfortably below typical typing
	// rhythm but above iPadOS double-fire window.
	private var lastHotkeyAt: CFTimeInterval = 0
	private var lastFocusAt: CFTimeInterval = 0
	var onLanguageChange: ((String?) -> Void)?

	init(host: UIViewController, keyForwardTarget: UIResponder) {
		self.host = host
		self.keyForwardTarget = keyForwardTarget
	}

	func start() {
		guard hiddenField == nil, let hostView = host?.view else { return }

		let field = LanguageSyncTextField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
		field.alpha = 0
		field.autocorrectionType = .no
		field.autocapitalizationType = .none
		field.spellCheckingType = .no
		field.smartDashesType = .no
		field.smartQuotesType = .no
		field.smartInsertDeleteType = .no
		field.keyForwardTarget = keyForwardTarget
		hostView.addSubview(field)
		noteFocusChange()
		field.becomeFirstResponder()
		hiddenField = field
		Diagnostics.note("layout-sync event=start firstResponder=\(field.isFirstResponder) hardwareKeyboard=\(GCKeyboard.coalesced != nil) lang=\(field.textInputMode?.primaryLanguage ?? "nil")")

		// Returning to the app restores first responder and posts a mode
		// notification: a focus move, not a user switch.
		foregroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
		) { [weak self] _ in self?.noteFocusChange() }
		// The field swaps its empty inputView when a hardware keyboard comes
		// or goes (see LanguageSyncTextField.inputView).
		for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
			keyboardObservers.append(NotificationCenter.default.addObserver(
				forName: name, object: nil, queue: .main
			) { [weak self] _ in
				self?.noteFocusChange()
				self?.hiddenField?.reloadInputViews()
			})
		}

		observer = NotificationCenter.default.addObserver(
			forName: UITextInputMode.currentInputModeDidChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] note in
			self?.handleChange(note: note)
		}
	}

	func stop() {
		if let obs = observer {
			NotificationCenter.default.removeObserver(obs)
			observer = nil
		}
		if let obs = foregroundObserver {
			NotificationCenter.default.removeObserver(obs)
			foregroundObserver = nil
		}
		keyboardObservers.forEach(NotificationCenter.default.removeObserver)
		keyboardObservers = []
		hiddenField?.resignFirstResponder()
		hiddenField?.removeFromSuperview()
		hiddenField = nil
	}

	// Step aside so the host view controller can become first responder
	// (e.g. when the soft keyboard is shown via 3-finger tap).
	func yieldFirstResponder() {
		noteFocusChange()
		hiddenField?.resignFirstResponder()
	}

	// Re-take first-responder status when the host VC has resigned (typically
	// after the soft keyboard is dismissed).
	func reclaimFirstResponder() {
		noteFocusChange()
		hiddenField?.becomeFirstResponder()
	}

	// Fires the host chord only for a real switch between two KNOWN input
	// languages. Focus moves (start, soft keyboard show/hide, foreground,
	// sheets) also post this notification, so within 0.5 s of one we only
	// re-seed. A toggle chord stays in sync only if every real switch sends
	// exactly one chord and nothing else does.
	private func handleChange(note: Notification) {
		let lang = currentLanguage(from: note)
		let now = CACurrentMediaTime()
		let focusChange = now - lastFocusAt < 0.5
		Diagnostics.note("layout-sync event=notification lang=\(lang ?? "nil") last=\(lastLanguage ?? "nil") focusChange=\(focusChange) fieldFirstResponder=\(hiddenField?.isFirstResponder ?? false)")
		guard let lang else { return }
		defer { lastLanguage = lang }
		guard Self.shouldSendHostSwitch(
			language: lang,
			last: lastLanguage,
			sinceFocus: now - lastFocusAt
		) else { return }
		// Coalesce iPadOS double notifications.
		guard now - lastHotkeyAt > 0.05 else { return }
		lastHotkeyAt = now
		onLanguageChange?(lang)
	}

	/// Only a switch between two known languages, away from any focus move,
	/// is a user's Globe/Caps switch.
	static func shouldSendHostSwitch(language: String?, last: String?, sinceFocus: CFTimeInterval) -> Bool {
		guard let language, let last, sinceFocus >= 0.5 else { return false }
		return language != last
	}

	// Called on every focus move: suppress firing briefly and re-seed the
	// known language once iPadOS has settled the new responder.
	private func noteFocusChange() {
		lastFocusAt = CACurrentMediaTime()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
			guard let self, let lang = self.hiddenField?.textInputMode?.primaryLanguage else { return }
			self.lastLanguage = lang
		}
	}

	// Prefer the mode advertised by the notification, fall back to whatever
	// the hidden field currently reports. Either may be nil if no responder
	// accepts text input at the moment.
	private func currentLanguage(from note: Notification?) -> String? {
		if let mode = note?.object as? UITextInputMode, let lang = mode.primaryLanguage {
			return lang
		}
		return hiddenField?.textInputMode?.primaryLanguage
	}
}
