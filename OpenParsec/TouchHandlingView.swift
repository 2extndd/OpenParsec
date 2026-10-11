import UIKit


class TouchController
{
	weak var viewController: UIViewController?

	init(viewController: UIViewController) {
		self.viewController = viewController
	}
	
	func onTouch(typeOfTap:Int, location:CGPoint, state: UIGestureRecognizer.State) {

		let x = Int32(location.x)
		let y = Int32(location.y)

		// Send the mouse input to the host
		let parsecTap = RemoteMouseButton(rawValue: UInt32(typeOfTap))
		switch state
		{
			case .began:
				CParsec.sendMouseMessage(parsecTap, x, y, true)
			case .changed:
				CParsec.sendMousePosition(x, y)
			case .ended:
				CParsec.sendMouseMessage(parsecTap, x, y, false)
			case .cancelled:
				CParsec.sendMouseMessage(
					parsecTap,
					x,
					y,
					false,
					releaseReason: .gestureCancelled
				)
			default:
				break
		}
	}

	func onTap(typeOfTap:Int, location:CGPoint) {

		let parsecTap = RemoteMouseButton(rawValue: UInt32(typeOfTap))
		// A quick second tap can land before the previous tap's delayed
		// release; release it now so the latch doesn't swallow this press.
		// The stale delayed release then becomes a no-op or an early release.
		CParsec.sendMouseClickMessage(parsecTap, false)

		if SettingsHandler.cursorMode == .direct {
			let x = Int32(location.x)
			let y = Int32(location.y)

			// Send the mouse input to the host
			// add release delay in case some games ignore instant key release
			CParsec.sendMouseMessage(parsecTap, x, y, true)
			DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
				CParsec.sendMouseMessage(parsecTap, x, y, false)
			}

		} else {
			CParsec.sendMouseClickMessage(parsecTap, true)
			DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
				CParsec.sendMouseClickMessage(parsecTap, false)
			}
		}
	}

	public func viewDidLoad() { }

}
