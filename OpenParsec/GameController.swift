import UIKit
import GameController

class GamepadController {
    
    private let maximumControllerCount: Int = 1
    private(set) var controllers = Set<GCController>()
	private(set) var mice = Set<GCMouse>()
	private let mouseInputLock = NSLock()
	private var mouseMovementAccumulator = ParsecDeltaAccumulator()
	private var mouseScrollAccumulator = ParsecDeltaAccumulator()
	// Parsec gamepad id per physical controller (1-based, reused after unplug).
	private var controllerIds: [ObjectIdentifier: UInt32] = [:]
    //private var panRecognizer: UIPanGestureRecognizer!
    weak var delegate: InputManagerDelegate?
	
	// weak: GCController/GCMouse handlers outlive the session controller.
	weak var viewController: UIViewController?
	
	init(viewController: UIViewController ) {
		self.viewController = viewController
	}
    
    public func viewDidLoad() {
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.didConnectController),
                                               name: NSNotification.Name.GCControllerDidConnect,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.didDisconnectController),
                                               name: NSNotification.Name.GCControllerDidDisconnect,
                                               object: nil)
		
		NotificationCenter.default.addObserver(self,
											   selector: #selector(self.didMouseConnectController),
											   name: NSNotification.Name.GCMouseDidConnect,
											   object: nil)
		NotificationCenter.default.addObserver(self,
											   selector: #selector(self.didMouseDisconnectController),
											   name: NSNotification.Name.GCMouseDidDisconnect,
											   object: nil)
	    
        GCController.startWirelessControllerDiscovery {}
		self.registerControllerHandler()
		self.registerMouseHandler()

    }
    
    func registerControllerHandler()
	{
		for controller in GCController.controllers() {
			let key = ObjectIdentifier(controller)
			guard controllerIds[key] == nil else { continue }
			let id = (UInt32(1)...).first { !controllerIds.values.contains($0) }!
			controllerIds[key] = id
			controllers.insert(controller)

			delegate?.inputManager(self, didConnect: controller)
			
			controller.extendedGamepad?.dpad.left.pressedChangedHandler =      { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.dpadLeft, pressed) }
			controller.extendedGamepad?.dpad.right.pressedChangedHandler =     { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.dpadRight, pressed) }
			controller.extendedGamepad?.dpad.up.pressedChangedHandler =        { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.dpadUp, pressed) }
			controller.extendedGamepad?.dpad.down.pressedChangedHandler =      { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.dpadDown, pressed) }
			
			// buttonA is labeled "X" (blue) on PS4 controller
			controller.extendedGamepad?.buttonA.pressedChangedHandler =        { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.a, pressed) }
			// buttonB is labeled "circle" (red) on PS4 controller
			controller.extendedGamepad?.buttonB.pressedChangedHandler =        { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.b, pressed) }
			// buttonX is labeled "square" (pink) on PS4 controller
			controller.extendedGamepad?.buttonX.pressedChangedHandler =        { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.x, pressed) }
			// buttonY is labeled "triangle" (green) on PS4 controller
			controller.extendedGamepad?.buttonY.pressedChangedHandler =        { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.y, pressed) }
			
			// buttonOptions is labeled "SHARE" on PS4 controller
			controller.extendedGamepad?.buttonOptions?.pressedChangedHandler = { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.back, pressed) }
			// buttonMenu is labeled "OPTIONS" on PS4 controller
			controller.extendedGamepad?.buttonMenu.pressedChangedHandler =     { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.start, pressed) }
			
			controller.extendedGamepad?.leftShoulder.pressedChangedHandler =   { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.leftShoulder, pressed) }
			controller.extendedGamepad?.rightShoulder.pressedChangedHandler =  { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.rightShoulder, pressed) }
			
			//controller.extendedGamepad?.leftTrigger.PressedChangedHandler =    { [weak self] (button, value, pressed) in self?.triggerButtonChangedHandler(RemoteGamepadAxis.leftTrigger, pressed) }
			controller.extendedGamepad?.leftTrigger.valueChangedHandler =      { [weak self] (button, value, pressed) in self?.triggerChangedHandler(id, RemoteGamepadAxis.leftTrigger, value, pressed) }
			//controller.extendedGamepad?.rightTrigger.pressedChangedHandler =   { [weak self] (button, value, pressed) in self?.triggerButtonChangedHandler(RemoteGamepadAxis.rightTrigger, pressed) }
			controller.extendedGamepad?.rightTrigger.valueChangedHandler =     { [weak self] (button, value, pressed) in self?.triggerChangedHandler(id, RemoteGamepadAxis.rightTrigger, value, pressed) }
			
			controller.extendedGamepad?.leftThumbstick.valueChangedHandler =   { [weak self] (button, xvalue, yvalue) in self?.thumbLstickChangedHandler(id, xvalue, yvalue) }
			controller.extendedGamepad?.rightThumbstick.valueChangedHandler =  { [weak self] (button, xvalue, yvalue) in self?.thumbRstickChangedHandler(id, xvalue, yvalue) }
			
			controller.extendedGamepad?.leftThumbstickButton?.pressedChangedHandler =  { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.leftStick, pressed) }
			controller.extendedGamepad?.rightThumbstickButton?.pressedChangedHandler = { [weak self] (button, value, pressed) in self?.buttonChangedHandler(id, RemoteGamepadButton.rightStick, pressed) }
		}
			

		
	}
	
	func registerMouseHandler() {
		for mouse in GCMouse.mice() {
			mice.insert(mouse)
			// GCMouse is the reliable button source in BOTH modes: trackpad touches
			// hit the UIScrollView, which doesn't forward them to the controller's
			// touchesBegan, so UIKit's buttonMask path alone loses presses (window
			// drag broke when this was gated to captured mode). Duplicates from the
			// UIKit path are filtered by the per-button latch in CParsec.
			// While an in-session overlay is open, clicks belong to the overlay.
			mouse.mouseInput?.leftButton.pressedChangedHandler = { (input: GCControllerButtonInput, v: Float, pressed: Bool) in
				guard !ParsecViewController.sessionOverlayActive || !pressed else { return }
				Diagnostics.note("mouse-button src=gcmouse button=left pressed=\(pressed)")
				CParsec.sendMouseClickMessage(.left, pressed)
				}
			mouse.mouseInput?.rightButton?.pressedChangedHandler = {(input: GCControllerButtonInput, v: Float, pressed: Bool) in
				guard !ParsecViewController.sessionOverlayActive || !pressed else { return }
				Diagnostics.note("mouse-button src=gcmouse button=right pressed=\(pressed)")
				CParsec.sendMouseClickMessage(.right, pressed)
				}
			mouse.mouseInput?.middleButton?.pressedChangedHandler = {(input: GCControllerButtonInput, v: Float, pressed: Bool) in
				guard !ParsecViewController.sessionOverlayActive || !pressed else { return }
				CParsec.sendMouseClickMessage(.middle, pressed)
				}
			mouse.mouseInput?.mouseMovedHandler = {[weak self] (input: GCMouseInput, v: Float, v2: Float) in
				self?.sendMouseMovement(x: Double(v / 1.25), y: Double(-v2 / 1.25))
			}
			// Scroll wheel: yAxis = vertical (send as y), xAxis = horizontal
			// (send as x). Previously these were swapped — pre-existing bug.
			// Also apply naturalScrolling + scrollSensitivity so the wheel
			// matches the trackpad's direction setting.
			mouse.mouseInput?.scroll.yAxis.valueChangedHandler = {[weak self] (axis: GCControllerAxisInput, value: Float) in
				DispatchQueue.main.async {
					self?.sendMouseScroll(x: 0, y: Double(value))
				}
			}
			mouse.mouseInput?.scroll.xAxis.valueChangedHandler = {[weak self] (axis: GCControllerAxisInput, value: Float) in
				DispatchQueue.main.async {
					self?.sendMouseScroll(x: Double(value), y: 0)
				}
			}
		}
	}
	
	// GCMouse owns pointer input only in captured mode and only while no
	// in-session overlay needs the local pointer.
	private static var capturedInputActive: Bool {
		SettingsHandler.pointerPresentationMode == .captured
			&& !ParsecViewController.sessionOverlayActive
	}

	// Diagnostics probe: for `seconds`, log the modifier chords GameController
	// sees so they can be compared with UIKit delivery (key-chord via=uikit) to
	// find which iPadOS-reserved shortcuts an app can still observe. Off by
	// default because keyboard handlers are global. Usage codes only.
	static func startKeyboardProbe(seconds: TimeInterval = 60) {
		guard let input = GCKeyboard.coalesced?.keyboardInput else {
			Diagnostics.note("key-probe result=no-keyboard")
			return
		}
		Diagnostics.note("key-probe event=start seconds=\(Int(seconds))")
		let modifiers: [GCKeyCode] = [.leftGUI, .rightGUI, .leftControl, .rightControl, .leftAlt, .rightAlt]
		input.keyChangedHandler = { input, _, keyCode, pressed in
			guard pressed, !modifiers.contains(keyCode) else { return }
			let held = modifiers.filter { input.button(forKeyCode: $0)?.isPressed == true }
			guard !held.isEmpty else { return }
			Diagnostics.note("key-chord via=gckeyboard usage=\(keyCode.rawValue) mods=\(held.map(\.rawValue))")
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
			input.keyChangedHandler = nil
			Diagnostics.note("key-probe event=stop")
		}
	}

	// Internal (not private) so tests can drive the captured-mode paths;
	// GCMouse itself cannot be synthesized.
	func sendMouseMovement(x: Double, y: Double) {
		// In native mode UIKit's unlocked hover path owns absolute motion.
		// GCMouse deltas are retained only for explicit captured mode so an
		// external mouse cannot generate duplicate absolute + relative sends.
		guard Self.capturedInputActive else { return }
		let transformed = ParsecPointerTransform.movement(
			x: x,
			y: y,
			sensitivity: SettingsHandler.mouseSensitivity,
			acceleration: SettingsHandler.mouseAcceleration
		)
		// GCMouse handlers fire on GameController's private background
		// queue (no handlerQueue is set to main). CParsec sends are
		// thread-safe, but the local-cursor overlay touches UIView
		// geometry — that MUST happen on the main thread or UIKit
		// traps. Dispatch the overlay update to main; keep the send
		// inline so input latency isn't affected.
		mouseInputLock.lock()
		let whole = mouseMovementAccumulator.consume(transformed)
		mouseInputLock.unlock()
		if let whole {
			CParsec.sendMouseDelta(whole.x, whole.y)
		}
		DispatchQueue.main.async { [weak self] in
			if let vc = self?.viewController as? ParsecViewController {
				vc.moveLocalCursor(
					byX: CGFloat(transformed.x),
					y: CGFloat(transformed.y)
				)
			}
		}
	}

	func sendMouseScroll(x: Double, y: Double) {
		// Native mode: the UIKit trackpad-scroll recognizer owns the wheel
		// (handleTrackpadScroll). Pointer-locked mode may not deliver UIKit
		// scroll events, so GCMouse owns it there — exactly one path sends.
		guard Self.capturedInputActive else { return }
		if let controller = viewController as? ParsecViewController,
		   !controller.shouldForwardRemoteScroll {
			return
		}
		let transformed = ParsecPointerTransform.scroll(
			x: x,
			y: y,
			sensitivity: SettingsHandler.scrollSensitivity,
			natural: SettingsHandler.naturalScrolling
		)
		mouseInputLock.lock()
		let whole = mouseScrollAccumulator.consume(transformed)
		mouseInputLock.unlock()
		if let whole {
			CParsec.sendWheelMsg(x: whole.x, y: whole.y)
		}
	}

	@objc func didMouseConnectController(_ notification: Notification) {
		self.registerMouseHandler()
	}
	
	@objc func didMouseDisconnectController(_ notification: Notification) {
		let mouse = notification.object as! GCMouse
		mice.remove(mouse)
		CParsec.releaseAllMouseButtons(reason: .mouseDisconnected)
		mouseInputLock.lock()
		mouseMovementAccumulator.reset()
		mouseScrollAccumulator.reset()
		mouseInputLock.unlock()
	}
	
	
	
    @objc func didConnectController(_ notification: Notification) {
        
        //guard controllers.count < maximumControllerCount else { return }
        //let controller = notification.object as! GCController
        self.registerControllerHandler()
    }
	
    @objc func didDisconnectController(_ notification: Notification) {
        
        let controller = notification.object as! GCController
        controllers.remove(controller)
        
        delegate?.inputManager(self, didDisconnect: controller)
		if let id = controllerIds.removeValue(forKey: ObjectIdentifier(controller)) {
			CParsec.sendGameControllerUnplugMessage(controllerId: id)
		}
    }
    
	func ButtonFloatToParsecInt(_ value: Float) -> Int16
	{
		// Int16(_:) traps on NaN or out-of-range input; clamp first.
		let clamped = value.isFinite ? min(max(value, -1), 1) : 0
		let newval: Float = (65535.0*clamped-1.0)/2.0
		return Int16(max(min(newval, Float(Int16.max)), Float(Int16.min)))
	}
    
    func buttonChangedHandler(_ controllerId: UInt32, _ button: RemoteGamepadButton, _ pressed: Bool) {
        CParsec.sendGameControllerButtonMessage(controllerId: controllerId, button, pressed:pressed)
    }
    
	//func triggerButtonChangedHandler(_ button: RemoteGamepadAxis, _ pressed: Bool) {
        //CParsec.sendGameControllerTriggerButtonMessage(controllerId: controllerId, button, pressed)
    //}
	
    func triggerChangedHandler(_ controllerId: UInt32, _ button:RemoteGamepadAxis, _ value: Float, _ pressed: Bool) {
        CParsec.sendGameControllerAxisMessage(controllerId: controllerId, button, ButtonFloatToParsecInt(value))
    }
    
	
    func thumbLstickChangedHandler(_ controllerId: UInt32, _ xvalue: Float, _ yvalue: Float) {
        CParsec.sendGameControllerAxisMessage(controllerId: controllerId, RemoteGamepadAxis.leftX, ButtonFloatToParsecInt(xvalue))
		CParsec.sendGameControllerAxisMessage(controllerId: controllerId, RemoteGamepadAxis.leftY, ButtonFloatToParsecInt(-yvalue))
		
    }
	
	func thumbRstickChangedHandler(_ controllerId: UInt32, _ xvalue: Float, _ yvalue: Float) {
        CParsec.sendGameControllerAxisMessage(controllerId: controllerId, RemoteGamepadAxis.rightX, ButtonFloatToParsecInt(xvalue))
		CParsec.sendGameControllerAxisMessage(controllerId: controllerId, RemoteGamepadAxis.rightY, ButtonFloatToParsecInt(-yvalue))
    }
    
}

protocol InputManagerDelegate: AnyObject {
    func inputManager(_ manager: GamepadController, didConnect controller: GCController)
    func inputManager(_ manager: GamepadController, didDisconnect controller: GCController)
}
