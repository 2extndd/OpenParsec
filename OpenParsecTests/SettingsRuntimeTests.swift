import XCTest
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import OpenParsec

/// Each test flips a Settings control (through the same UserDefaults key the
/// SettingsView @AppStorage writes) and asserts the effect where it leaves the
/// app: the ParsecService boundary (keyboard/mouse/wheel/video-config calls),
/// a UIKit property, or a view the session reads.
@MainActor
final class SettingsRuntimeTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private var previousService: ParsecService?
    private var previousBitrate = 0
    private var service: SettingsRecordingService!

    override func setUp() {
        super.setUp()
        for id in ParsecSettingID.allCases {
            if let value = UserDefaults.standard.object(forKey: id.rawValue) {
                savedDefaults[id.rawValue] = value
            }
        }
        previousService = CParsec.parsecImpl
        previousBitrate = DataManager.model.bitrate
        CParsec.releaseAllKeyboardKeys(reason: .reconnect)
        CParsec.releaseAllMouseButtons(reason: .gestureCancelled)
        service = SettingsRecordingService()
        CParsec.parsecImpl = service
        ParsecViewController.sessionOverlayActive = false
    }

    override func tearDown() {
        CParsec.releaseAllKeyboardKeys(reason: .sessionDisconnected)
        CParsec.releaseAllMouseButtons(reason: .gestureCancelled)
        // Let delayed tap releases (20 ms, global queue) land on our recorder.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        CParsec.parsecImpl = previousService
        DataManager.model.bitrate = previousBitrate
        for id in ParsecSettingID.allCases {
            if let value = savedDefaults[id.rawValue] {
                UserDefaults.standard.set(value, forKey: id.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: id.rawValue)
            }
        }
        super.tearDown()
    }

    /// Writes a value exactly as SwiftUI @AppStorage does (raw value under the key).
    private func set(_ id: ParsecSettingID, _ value: Any) {
        UserDefaults.standard.set(value, forKey: id.rawValue)
    }

    private func loadedController() -> ParsecViewController {
        let controller = ParsecViewController()
        controller.loadViewIfNeeded()
        return controller
    }

    // MARK: Binding: every SettingsView key reaches the runtime accessor

    func testEverySettingsViewKeyIsReadByTheRuntimeAccessor() {
        set(.resolution, ParsecResolution.r1920x1080_16_9.rawValue)
        set(.bitrate, 25)
        set(.decoder, DecoderPref.h265.rawValue)
        set(.decoderCompatibility, true)
        set(.preferredFramesPerSecond, 30)
        set(.pointerPresentationMode, PointerPresentationMode.captured.rawValue)
        set(.naturalScrolling, false)
        set(.scrollSensitivity, 2.5)
        set(.scrollGlideDuration, 0.3)
        set(.mouseSensitivity, 1.7)
        set(.mouseAcceleration, 0.4)
        set(.cursorMode, CursorMode.direct.rawValue)
        set(.rightClickPosition, RightClickPosition.secondFinger.rawValue)
        set(.cursorScale, 1.5)
        set(.captureSystemKeys, false)
        set(.hostShortcutToolbarMode, HostShortcutToolbarMode.windows.rawValue)
        set(.windowsKeyboardMode, WindowsKeyboardMode.commandAsControl.rawValue)
        set(.syncKeyboardLayout, false)
        set(.layoutSyncHotkey, LayoutSyncHotkey.altShift.rawValue)
        set(.ctrlShiftEmulatesCmdSpace, true)
        set(.backtickEmulatesCmdSpace, true)
        set(.showKeyboardButton, false)
        set(.hideStatusBar, false)
        set(.noOverlay, true)
        set(.saveSessionSettings, false)

        XCTAssertEqual(SettingsHandler.resolution, .r1920x1080_16_9)
        XCTAssertEqual(SettingsHandler.bitrate, 25)
        XCTAssertEqual(SettingsHandler.decoder, .h265)
        XCTAssertTrue(SettingsHandler.decoderCompatibility)
        XCTAssertEqual(SettingsHandler.preferredFramesPerSecond, 30)
        XCTAssertEqual(SettingsHandler.pointerPresentationMode, .captured)
        XCTAssertFalse(SettingsHandler.naturalScrolling)
        XCTAssertEqual(SettingsHandler.scrollSensitivity, 2.5)
        XCTAssertEqual(SettingsHandler.scrollGlideDuration, 0.3)
        XCTAssertEqual(SettingsHandler.mouseSensitivity, 1.7)
        XCTAssertEqual(SettingsHandler.mouseAcceleration, 0.4)
        XCTAssertEqual(SettingsHandler.cursorMode, .direct)
        XCTAssertEqual(SettingsHandler.rightClickPosition, .secondFinger)
        XCTAssertEqual(SettingsHandler.cursorScale, 1.5)
        XCTAssertFalse(SettingsHandler.captureSystemKeys)
        XCTAssertEqual(SettingsHandler.hostShortcutToolbarMode, .windows)
        XCTAssertEqual(SettingsHandler.windowsKeyboardMode, .commandAsControl)
        XCTAssertFalse(SettingsHandler.syncKeyboardLayout)
        XCTAssertEqual(SettingsHandler.layoutSyncHotkey, .altShift)
        XCTAssertTrue(SettingsHandler.ctrlShiftEmulatesCmdSpace)
        XCTAssertTrue(SettingsHandler.backtickEmulatesCmdSpace)
        XCTAssertFalse(SettingsHandler.showKeyboardButton)
        XCTAssertFalse(SettingsHandler.hideStatusBar)
        XCTAssertTrue(SettingsHandler.noOverlay)
        XCTAssertFalse(SettingsHandler.saveSessionSettings)
    }

    // MARK: Stream

    /// ParsecSDKBridge.connect/applyConfig (device-only) copy exactly these
    /// expressions into ParsecClientConfig.video[0/1].
    func testResolutionDecoderAndCompatibilityProduceTheConnectConfigValues() {
        for resolution in ParsecResolution.allCases where resolution != .client {
            set(.resolution, resolution.rawValue)
            let label = resolution.rawValue
            if resolution == .host {
                XCTAssertEqual(SettingsHandler.resolution.width, 0)
                XCTAssertEqual(SettingsHandler.resolution.height, 0)
                continue
            }
            let dims = label.split(separator: " ")[0].split(separator: "x").compactMap { Int($0) }
            XCTAssertEqual(SettingsHandler.resolution.width, dims[0], label)
            XCTAssertEqual(SettingsHandler.resolution.height, dims[1], label)
        }
        set(.resolution, ParsecResolution.client.rawValue)
        XCTAssertGreaterThan(SettingsHandler.resolution.width, 0)
        XCTAssertGreaterThanOrEqual(SettingsHandler.resolution.width, SettingsHandler.resolution.height)

        set(.decoder, DecoderPref.h265.rawValue)
        XCTAssertTrue(SettingsHandler.decoder == .h265)
        set(.decoder, DecoderPref.h264.rawValue)
        XCTAssertFalse(SettingsHandler.decoder == .h265)
        set(.decoderCompatibility, true)
        XCTAssertTrue(SettingsHandler.decoderCompatibility)
    }

    func testMaxBitrateChangePushesHostVideoConfigLiveAndHostDefaultDoesNot() throws {
        let controller = loadedController()
        DataManager.model.bitrate = 10

        set(.bitrate, 25)
        SettingsHandler.notifyChanged(.bitrate)
        XCTAssertEqual(DataManager.model.bitrate, 25)
        XCTAssertEqual(service.videoConfigPushes, 1)

        // The pushed wire carries the Mbps value (same struct the bridge encodes).
        var wire = ParsecUserDataVideoConfig()
        wire.video[0].encoderMaxBitrate = DataManager.model.bitrate
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
        )
        XCTAssertEqual((json["video"] as? [[String: Any]])?.first?["encoderMaxBitrate"] as? Int, 25)

        // Same value again: no second encoder reconfigure.
        SettingsHandler.notifyChanged(.bitrate)
        XCTAssertEqual(service.videoConfigPushes, 1)

        // "Host Default" keeps the current stream rate until reconnect.
        set(.bitrate, 0)
        SettingsHandler.notifyChanged(.bitrate)
        XCTAssertEqual(DataManager.model.bitrate, 25)
        XCTAssertEqual(service.videoConfigPushes, 1)
        _ = controller
    }

    func testLocalDisplayRefreshDrivesTheRenderLoopRate() {
        let controller = loadedController()
        let glk = (controller.glkView as? ParsecGLKViewController)?.glkViewController
        for fps in [30, 60, 120] {
            set(.preferredFramesPerSecond, fps)
            SettingsHandler.notifyChanged(.preferredFramesPerSecond)
            XCTAssertEqual(glk?.preferredFramesPerSecond, fps)
        }
        set(.preferredFramesPerSecond, 0)
        SettingsHandler.notifyChanged(.preferredFramesPerSecond)
        XCTAssertEqual(glk?.preferredFramesPerSecond, UIScreen.main.maximumFramesPerSecond)

        // A fresh session surface picks the setting up at creation too.
        set(.preferredFramesPerSecond, 30)
        let fresh = loadedController()
        XCTAssertEqual(
            (fresh.glkView as? ParsecGLKViewController)?.glkViewController.preferredFramesPerSecond,
            30
        )
    }

    func testPoorNetworkPresetBitrateReachesTheHostWhenSettingsObserverFires() {
        let controller = loadedController()
        DataManager.model.bitrate = 30
        set(.bitrate, 30)
        SettingsHandler.applyPoorNetworkPreset()
        // SettingsView's .onChange(of: bitrate) posts this for the preset write.
        SettingsHandler.notifyChanged(.bitrate)
        XCTAssertEqual(DataManager.model.bitrate, 5)
        XCTAssertEqual(service.videoConfigPushes, 1)
        XCTAssertEqual(SettingsHandler.resolution.width, 1280)
        XCTAssertEqual(SettingsHandler.resolution.height, 720)
        XCTAssertTrue(SettingsHandler.decoder == .h265)
        XCTAssertFalse(SettingsHandler.decoderCompatibility)
        XCTAssertFalse(SettingsHandler.savedConstantFps)
        XCTAssertFalse(DataManager.model.constantFps)
        XCTAssertEqual(SettingsHandler.macStreamScale, .half)
        _ = controller
    }

    // MARK: - Mac stream size (mac-helper/ParsecLowDisplay)

    private let mac1 = ParsecDisplayConfig(name: "Built-in Retina Display", adapterName: "", id: "1")
    private let mac3 = ParsecDisplayConfig(name: "LG ULTRAGEAR", adapterName: "", id: "3")
    private let low = ParsecDisplayConfig(name: "Parsec Low", adapterName: "", id: "16")

    private func resetMacLow(output: String, hostOS: Int = 2) {
        service.hostOSValue = hostOS
        CParsec.macLowSource = nil
        CParsec.lastMacLowKeyAt = .distantPast
        DataManager.model.output = output
        service.reset()
    }

    func testChoosingMacStreamScaleSendsTheHelperHotkey() {
        resetMacLow(output: "1")
        CParsec.setMacStreamScale(.half)
        XCTAssertEqual(SettingsHandler.macStreamScale, .half)
        // Ctrl+Opt+Cmd+J, released in reverse.
        XCTAssertEqual(service.keyboard, ["224:true", "226:true", "227:true", "13:true", "13:false", "227:false", "226:false", "224:false"])
        service.reset()
        CParsec.setMacStreamScale(.native)
        XCTAssertEqual(service.keyboard.filter { $0.hasSuffix(":true") }, ["224:true", "226:true", "227:true", "11:true"])
    }

    func testMacLowDisplayFullCycleOnAMacHost() {
        resetMacLow(output: "1")
        SettingsHandler.macStreamScale = .half

        // Connect: no virtual display yet → ask the helper for one, once.
        CParsec.reconcileMacLowDisplay([mac1, mac3])
        XCTAssertEqual(service.keyboard.filter { $0.hasSuffix(":true") }, ["224:true", "226:true", "227:true", "13:true"])
        service.reset()
        CParsec.reconcileMacLowDisplay([mac1, mac3])
        XCTAssertEqual(service.keyboard, [], "rate-limited: no helper, no hotkey storm")

        // The helper mirrored display 1 into "Parsec Low": stream it.
        CParsec.reconcileMacLowDisplay([low, mac3])
        XCTAssertEqual(DataManager.model.output, "16")
        XCTAssertEqual(service.videoConfigPushes, 1)
        XCTAssertEqual(CParsec.macLowSource, "1")
        CParsec.reconcileMacLowDisplay([low, mac3])
        XCTAssertEqual(service.videoConfigPushes, 1, "already streaming it")

        // "Switch Display" moved the mirror to display 3.
        CParsec.reconcileMacLowDisplay([mac1, low])
        XCTAssertEqual(CParsec.macLowSource, "3")

        // Native: the helper removed it → back to the display it mirrored.
        SettingsHandler.macStreamScale = .native
        DataManager.model.output = "none" // case 12's stale-reset of the vanished id
        CParsec.reconcileMacLowDisplay([mac1, mac3])
        XCTAssertEqual(DataManager.model.output, "3")
        XCTAssertNotEqual(SettingsHandler.savedDisplayOutput, "16", "the virtual display is never remembered")
    }

    func testMacLowDisplayIsIgnoredOnOtherHosts() {
        resetMacLow(output: "1", hostOS: 0) // Windows
        SettingsHandler.macStreamScale = .half
        CParsec.reconcileMacLowDisplay([mac1, low])
        XCTAssertEqual(service.keyboard, [])
        XCTAssertEqual(DataManager.model.output, "1")
        XCTAssertEqual(service.videoConfigPushes, 0)
    }

    // MARK: Pointer & Trackpad

    func testPointerModeSelectsLockAndTheSingleScrollRoute() {
        let controller = loadedController()
        let gamepad: GamepadController = controller.gamePadController
        let pan = FakePan(target: nil, action: nil)
        set(.naturalScrolling, true)
        set(.scrollSensitivity, 1.0)
        set(.mouseSensitivity, 1.0)
        set(.mouseAcceleration, 0.0)

        set(.pointerPresentationMode, PointerPresentationMode.native.rawValue)
        XCTAssertFalse(controller.prefersPointerLocked)
        scroll(controller, pan, dy: 10)
        gamepad.sendMouseScroll(x: 0, y: 10)
        gamepad.sendMouseMovement(x: 10, y: 0)
        XCTAssertEqual(service.wheel, ["0:10"], "native: UIKit trackpad owns wheel, GCMouse sends nothing")
        XCTAssertEqual(service.deltas, [])

        service.reset()
        set(.pointerPresentationMode, PointerPresentationMode.captured.rawValue)
        XCTAssertTrue(controller.prefersPointerLocked)
        scroll(controller, pan, dy: 10)
        gamepad.sendMouseScroll(x: 0, y: 10)
        gamepad.sendMouseMovement(x: 10, y: 0)
        XCTAssertEqual(service.wheel, ["0:10"], "captured: GCMouse owns wheel, UIKit sends nothing")
        XCTAssertEqual(service.deltas, ["10:0"])
    }

    func testNaturalScrollingAndScrollSpeedShapeTheWheelSentToHost() {
        let controller = loadedController()
        let pan = FakePan(target: nil, action: nil)
        set(.pointerPresentationMode, PointerPresentationMode.native.rawValue)
        set(.scrollGlideDuration, 0.0)

        set(.naturalScrolling, true)
        set(.scrollSensitivity, 1.0)
        scroll(controller, pan, dy: 10)
        set(.scrollSensitivity, 2.0)
        scroll(controller, pan, dy: 10)
        set(.naturalScrolling, false)
        scroll(controller, pan, dy: 10)
        XCTAssertEqual(service.wheel, ["0:10", "0:20", "0:-20"])

        // Captured mode wheel (GCMouse) honors the same two settings.
        service.reset()
        set(.pointerPresentationMode, PointerPresentationMode.captured.rawValue)
        set(.naturalScrolling, true)
        set(.scrollSensitivity, 3.0)
        controller.gamePadController.sendMouseScroll(x: 0, y: 2)
        set(.naturalScrolling, false)
        controller.gamePadController.sendMouseScroll(x: 0, y: 2)
        XCTAssertEqual(service.wheel, ["0:6", "0:-6"])
    }

    func testScrollGlideZeroStopsAndPositiveGlidesThenStopsAtDuration() {
        let controller = loadedController()
        let pan = FakePan(target: nil, action: nil)
        set(.pointerPresentationMode, PointerPresentationMode.native.rawValue)
        set(.naturalScrolling, true)
        set(.scrollSensitivity, 1.0)

        set(.scrollGlideDuration, 0.0)
        flick(controller, pan)
        XCTAssertNil(controller.momentumDisplayLink, "glide 0 must stop immediately")
        let afterLift = service.wheel.count
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(service.wheel.count, afterLift)

        set(.scrollGlideDuration, 0.3)
        flick(controller, pan)
        XCTAssertNotNil(controller.momentumDisplayLink)
        let glideStart = service.wheel.count
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThan(service.wheel.count, glideStart, "glide keeps scrolling after lift")
        XCTAssertTrue(service.wheel.suffix(from: glideStart).allSatisfy { !$0.hasPrefix("0:-") },
                      "glide continues in the flick direction")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(controller.momentumDisplayLink, "glide ends by the configured duration")
    }

    func testPointerSpeedAndAccelerationScaleRelativeMotion() {
        let controller = loadedController()
        let gamepad: GamepadController = controller.gamePadController
        set(.pointerPresentationMode, PointerPresentationMode.captured.rawValue)

        set(.mouseSensitivity, 2.0)
        set(.mouseAcceleration, 0.0)
        gamepad.sendMouseMovement(x: 10, y: 0)
        set(.mouseSensitivity, 1.0)
        set(.mouseAcceleration, 1.0) // speed 10/5 = 2 → scale 1 + 2
        gamepad.sendMouseMovement(x: 10, y: 0)
        XCTAssertEqual(service.deltas, ["20:0", "30:0"])

        // Touchpad finger drag uses the same two settings.
        service.reset()
        set(.cursorMode, CursorMode.touchpad.rawValue)
        set(.mouseSensitivity, 2.0)
        set(.mouseAcceleration, 0.0)
        let pan = FakePan(target: nil, action: nil)
        pan.fakeTouches = 1
        pan.fakeState = .began
        pan.fakeTranslation = CGPoint(x: 10, y: 0)
        controller.handlePanGesture(pan)
        pan.fakeState = .ended
        controller.handlePanGesture(pan)
        XCTAssertEqual(service.deltas, ["20:0"])
    }

    // MARK: Touchscreen

    func testFingerModeTouchpadSendsRelativeAndDirectSendsAbsolute() {
        let controller = loadedController()
        let pan = FakePan(target: nil, action: nil)
        pan.fakeTouches = 1
        let tap = FakeTap(target: nil, action: nil)
        tap.fakeLocation = CGPoint(x: 40, y: 50)

        set(.cursorMode, CursorMode.touchpad.rawValue)
        set(.mouseSensitivity, 1.0)
        set(.mouseAcceleration, 0.0)
        pan.fakeState = .began
        pan.fakeTranslation = CGPoint(x: 7, y: 3)
        controller.handlePanGesture(pan)
        pan.fakeState = .ended
        controller.handlePanGesture(pan)
        controller.handleSingleFingerTap(tap)
        XCTAssertEqual(service.deltas, ["7:3"])
        XCTAssertEqual(service.positions, [])
        XCTAssertEqual(service.mouseButtons.first, "click:1:true", "touchpad tap clicks at the cursor")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05)) // delayed tap release
        service.reset()
        set(.cursorMode, CursorMode.direct.rawValue)
        pan.fakeState = .began
        pan.fakeLocation = CGPoint(x: 100, y: 120)
        controller.handlePanGesture(pan)
        pan.fakeState = .ended
        controller.handlePanGesture(pan)
        let p = controller.contentView.convert(CGPoint(x: 100, y: 120), from: controller.view)
        XCTAssertEqual(service.deltas, [])
        XCTAssertEqual(service.positions, ["\(Int32(p.x)):\(Int32(p.y))"])
        XCTAssertEqual(service.mouseButtons, ["click:1:true", "click:1:false"], "direct drag holds left button")

        service.reset()
        controller.handleSingleFingerTap(tap)
        let t = controller.contentView.convert(tap.fakeLocation, from: controller.view)
        XCTAssertEqual(service.mouseButtons.first, "positioned:1:\(Int32(t.x)):\(Int32(t.y)):true",
                       "direct tap clicks at the finger")
    }

    func testTwoFingerTapRightClickPositionPicksTheConfiguredPoint() {
        let controller = loadedController()
        set(.cursorMode, CursorMode.direct.rawValue)
        let tap = FakeTap(target: nil, action: nil)
        tap.fakeTouchLocations = [CGPoint(x: 10, y: 20), CGPoint(x: 90, y: 80)]
        tap.fakeLocation = CGPoint(x: 50, y: 50)

        let cases: [(RightClickPosition, CGPoint)] = [
            (.firstFinger, CGPoint(x: 10, y: 20)),
            (.middle, CGPoint(x: 50, y: 50)),
            (.secondFinger, CGPoint(x: 90, y: 80)),
        ]
        for (position, expected) in cases {
            service.reset()
            set(.rightClickPosition, position.rawValue)
            controller.handleTwoFingerTap(tap)
            let p = controller.contentView.convert(expected, from: controller.view)
            XCTAssertEqual(service.mouseButtons.first, "positioned:3:\(Int32(p.x)):\(Int32(p.y)):true",
                           "\(position)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testCursorSizeScalesTheHostCursorEvenWhenStationary() {
        set(.pointerPresentationMode, PointerPresentationMode.native.rawValue)
        var info = MouseInfo()
        info.mouseX = 200
        info.mouseY = 300
        info.cursorWidth = 20
        info.cursorHeight = 10
        info.cursorHotX = 4
        info.cursorHotY = 2
        info.cursorImg = Self.onePixelImage()
        service.mouseInfo = info
        let controller = loadedController()

        set(.cursorScale, 1.0)
        controller.updateImage()
        XCTAssertEqual(controller.u?.frame, CGRect(x: 196, y: 298, width: 20, height: 10))

        set(.cursorScale, 2.0) // cursor has not moved
        controller.updateImage()
        XCTAssertEqual(controller.u?.frame, CGRect(x: 192, y: 296, width: 40, height: 20))
    }

    // MARK: Keyboard

    func testCaptureCommandShortcutsRegistersPriorityCommandsThatReachHost() {
        let controller = loadedController()
        set(.captureSystemKeys, false)
        XCTAssertTrue(controller.keyCommands?.isEmpty ?? true)

        set(.captureSystemKeys, true)
        let commands = controller.keyCommands ?? []
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.allSatisfy { $0.modifierFlags.contains(.command) })
        if #available(iOS 15.0, *) {
            XCTAssertTrue(commands.allSatisfy { $0.wantsPriorityOverSystemBehavior })
        }
        // What a captured ⌘C does at the host boundary.
        controller.handleCapturedKey(UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(UIResponder.copy(_:))))
        XCTAssertEqual(service.keyboard, ["227:true", "6:true", "6:false", "227:false"])
    }

    func testShortcutButtonsAboveKeyboardFollowModeAndHost() {
        let controller = loadedController()
        // hostOSValue: 2 = macOS, 0 = Windows, -1 = not yet known.
        let table: [(HostShortcutToolbarMode, Int, Bool, Bool)] = [
            (.automatic, 2, true, false),
            (.automatic, 0, false, true),
            (.automatic, -1, true, true),
            (.macOS, 0, true, false),
            (.windows, 2, false, true),
            (.both, 2, true, true),
            (.off, 0, false, false),
        ]
        for (mode, host, mac, windows) in table {
            service.hostOSValue = host
            set(.hostShortcutToolbarMode, mode.rawValue)
            SettingsHandler.notifyChanged(.hostShortcutToolbarMode)
            let keys = Self.keyTexts(in: controller.inputAccessoryView)
            XCTAssertEqual(keys.contains("MAC_INPUT_SOURCE"), mac, "\(mode) host=\(host)")
            XCTAssertEqual(keys.contains("WIN_START"), windows, "\(mode) host=\(host)")
            XCTAssertTrue(keys.contains("F1"), "base keys always present")
        }
    }

    func testWindowsCommandKeyModeMapsOnWindowsHostAndIsDirectOnMac() {
        let command = RemoteKeyCode(rawValue: 227)
        func mapped() -> UInt32 {
            ParsecWindowsKeyboardMapping.map(
                command,
                mode: SettingsHandler.effectiveWindowsKeyboardMode,
                intent: .configured
            ).rawValue
        }
        set(.windowsKeyboardMode, WindowsKeyboardMode.commandAsControl.rawValue)
        service.hostOSValue = 0
        XCTAssertEqual(mapped(), 224, "Windows host: ⌘ sends Ctrl")
        service.hostOSValue = 2
        XCTAssertEqual(mapped(), 227, "macOS host: always Direct")
        set(.windowsKeyboardMode, WindowsKeyboardMode.direct.rawValue)
        service.hostOSValue = 0
        XCTAssertEqual(mapped(), 227, "Win key mode")

        // Switching the mode releases held keys so press/release stay paired.
        let controller = loadedController()
        CParsec.sendKeyboardMessage(event: KeyBoardKeyEvent(key: command, isPressBegin: true))
        set(.windowsKeyboardMode, WindowsKeyboardMode.commandAsControl.rawValue)
        SettingsHandler.notifyChanged(.windowsKeyboardMode)
        XCTAssertEqual(service.keyboard, ["227:true", "227:false"])
        _ = controller
    }

    // MARK: Language Switching

    // Focus moves (start, soft keyboard, foreground) post the same
    // notification as a Globe switch; only a known → different known
    // language away from a focus move may send the host chord.
    func testLanguageSwitchDecisionIgnoresFocusMovesAndUnknownLanguages() {
        typealias C = LanguageSyncCoordinator
        XCTAssertTrue(C.shouldSendHostSwitch(language: "ru-RU", last: "en-US", sinceFocus: 2))
        XCTAssertFalse(C.shouldSendHostSwitch(language: "ru-RU", last: "en-US", sinceFocus: 0.2))
        XCTAssertFalse(C.shouldSendHostSwitch(language: "en-US", last: "en-US", sinceFocus: 2))
        XCTAssertFalse(C.shouldSendHostSwitch(language: nil, last: "en-US", sinceFocus: 2))
        XCTAssertFalse(C.shouldSendHostSwitch(language: "ru-RU", last: nil, sinceFocus: 2))
    }

    // One physical action = one host toggle. Device log 11:37:42–48: ⌃⇧ tapped
    // ~1/s alternated sent=true/false under the old 0.8 s window.
    func testLanguageSwitchPairsOnlyMacroWithIPadChange() {
        let same = ParsecViewController.isSameLanguageSwitchAction
        XCTAssertFalse(same(false, 10, nil))
        XCTAssertFalse(same(false, 10.2, (10, false)), "repeated ⌃⇧ is deliberate")
        XCTAssertFalse(same(true, 10.2, (10, true)), "repeated Globe is deliberate")
        XCTAssertTrue(same(true, 10.2, (10, false)), "iPad change right after ⌃⇧")
        XCTAssertTrue(same(false, 10.2, (10, true)), "⌃⇧ right after iPad change")
        XCTAssertFalse(same(true, 10.4, (10, false)), "separate Globe press")
    }

    func testRapidCtrlShiftAndPairedIPadChangeToggleOncePerPress() {
        let controller = loadedController()
        let macro = ["227:true", "44:true", "44:false", "227:false"]
        let bare = ["224:true", "225:true", "225:false", "224:false"]
        set(.ctrlShiftEmulatesCmdSpace, true)
        set(.syncKeyboardLayout, true)
        set(.layoutSyncHotkey, LayoutSyncHotkey.cmdSpace.rawValue)
        ctrlShift(controller)
        ctrlShift(controller)
        XCTAssertEqual(service.keyboard, bare + macro + bare + macro)

        // The iPad's own language change from that same press is not a 2nd toggle,
        service.reset()
        controller.startLanguageSyncIfNeeded()
        defer { controller.stopLanguageSync() }
        controller.languageSync?.onLanguageChange?("en-US")
        XCTAssertEqual(service.keyboard, [])
        // but the pair is consumed: the next Globe press switches again.
        controller.languageSync?.onLanguageChange?("ru-RU")
        XCTAssertEqual(service.keyboard, macro)
    }

    func testFollowIPadLanguageSendsTheConfiguredHostChord() {
        let expected: [(LayoutSyncHotkey, [String])] = [
            (.cmdSpace, ["227:true", "44:true", "44:false", "227:false"]),
            (.ctrlSpace, ["224:true", "44:true", "44:false", "224:false"]),
            (.ctrlShift, ["224:true", "225:true", "225:false", "224:false"]),
            (.altSpace, ["226:true", "44:true", "44:false", "226:false"]),
            (.altShift, ["226:true", "225:true", "225:false", "226:false"]),
            (.none, []),
        ]
        set(.syncKeyboardLayout, true)
        for (hotkey, events) in expected {
            service.reset()
            set(.layoutSyncHotkey, hotkey.rawValue)
            changeInputLanguage()
            XCTAssertEqual(service.keyboard, events, "\(hotkey)")
        }
        // ⌘Space is raw so "⌘ sends Ctrl" on a Windows host can't turn it into Ctrl+Space.
        service.reset()
        service.hostOSValue = 0
        set(.windowsKeyboardMode, WindowsKeyboardMode.commandAsControl.rawValue)
        set(.layoutSyncHotkey, LayoutSyncHotkey.cmdSpace.rawValue)
        changeInputLanguage()
        XCTAssertEqual(service.intents, [.raw, .raw, .raw, .raw])

        service.reset()
        set(.syncKeyboardLayout, false)
        changeInputLanguage()
        XCTAssertEqual(service.keyboard, [], "Follow iPad Language off sends nothing")
    }

    func testCtrlShiftSendsCommandSpaceOnlyWhenEnabledAndClean() {
        let controller = loadedController()
        let macro = ["227:true", "44:true", "44:false", "227:false"]
        let bare = ["224:true", "225:true", "225:false", "224:false"]

        set(.ctrlShiftEmulatesCmdSpace, false)
        ctrlShift(controller)
        XCTAssertEqual(service.keyboard, bare)

        service.reset()
        set(.ctrlShiftEmulatesCmdSpace, true)
        ctrlShift(controller)
        XCTAssertEqual(service.keyboard, bare + macro)

        // ⌃⇧X is a real shortcut, not the bare chord.
        service.reset()
        controller.hardwareKeyBegan(.keyboardLeftControl, modifiers: .control)
        controller.hardwareKeyBegan(.keyboardLeftShift, modifiers: [.control, .shift])
        controller.hardwareKeyBegan(.keyboardX, modifiers: [.control, .shift])
        controller.hardwareKeyEnded(.keyboardX)
        controller.hardwareKeyEnded(.keyboardLeftShift)
        controller.hardwareKeyEnded(.keyboardLeftControl)
        XCTAssertFalse(service.keyboard.contains("44:true"))
    }

    func testBacktickSendsCommandSpaceOnlyWhenEnabledAndBare() {
        let controller = loadedController()
        let macro = ["227:true", "44:true", "44:false", "227:false"]

        set(.backtickEmulatesCmdSpace, false)
        controller.hardwareKeyBegan(.keyboardGraveAccentAndTilde, modifiers: [])
        controller.hardwareKeyEnded(.keyboardGraveAccentAndTilde)
        XCTAssertEqual(service.keyboard, ["53:true", "53:false"])

        service.reset()
        set(.backtickEmulatesCmdSpace, true)
        controller.hardwareKeyBegan(.keyboardGraveAccentAndTilde, modifiers: [])
        controller.hardwareKeyBegan(.keyboardGraveAccentAndTilde, modifiers: []) // auto-repeat
        controller.hardwareKeyEnded(.keyboardGraveAccentAndTilde)
        XCTAssertEqual(service.keyboard, macro, "fires once, swallows the ` key")

        service.reset()
        controller.hardwareKeyBegan(.keyboardGraveAccentAndTilde, modifiers: .shift)
        controller.hardwareKeyEnded(.keyboardGraveAccentAndTilde)
        XCTAssertEqual(service.keyboard, ["53:true", "53:false"], "⇧` (tilde) still types")
    }

    // MARK: Interface

    func testRememberSessionChoicesGatesRestoredSessionState() {
        set(.savedMuted, true)
        set(.savedZoomEnabled, true)
        set(.savedConstantFps, true)

        set(.saveSessionSettings, true)
        let restored = ParsecView(nil)
        XCTAssertTrue(restored.muted)
        XCTAssertTrue(restored.zoomEnabled)
        XCTAssertTrue(restored.constantFps)

        set(.saveSessionSettings, false)
        let fresh = ParsecView(nil)
        XCTAssertFalse(fresh.muted)
        XCTAssertFalse(fresh.zoomEnabled)
        XCTAssertFalse(fresh.constantFps)
    }

    // MARK: Diagnostics

    func testKeyboardProbeAndDiagnosticsLogRecordEvidence() {
        GamepadController.startKeyboardProbe(seconds: 0.01)
        let log = Diagnostics.peek() ?? ""
        XCTAssertTrue(log.contains("key-probe"), "probe start (or no-keyboard) is logged")
        XCTAssertTrue(Diagnostics.hasLog)
    }

    // MARK: Helpers

    private func scroll(_ controller: ParsecViewController, _ pan: FakePan, dy: CGFloat) {
        pan.fakeTranslation = .zero
        pan.fakeVelocity = .zero
        pan.fakeState = .began
        controller.handleTrackpadScroll(pan)
        pan.fakeState = .changed
        pan.fakeTranslation = CGPoint(x: 0, y: dy)
        controller.handleTrackpadScroll(pan)
        pan.fakeState = .cancelled
        controller.handleTrackpadScroll(pan)
    }

    private func flick(_ controller: ParsecViewController, _ pan: FakePan) {
        pan.fakeTranslation = .zero
        pan.fakeState = .began
        controller.handleTrackpadScroll(pan)
        pan.fakeState = .changed
        pan.fakeTranslation = CGPoint(x: 0, y: 40)
        pan.fakeVelocity = CGPoint(x: 0, y: 1000)
        controller.handleTrackpadScroll(pan)
        pan.fakeState = .ended
        controller.handleTrackpadScroll(pan)
    }

    private func ctrlShift(_ controller: ParsecViewController) {
        controller.hardwareKeyBegan(.keyboardLeftControl, modifiers: .control)
        controller.hardwareKeyBegan(.keyboardLeftShift, modifiers: [.control, .shift])
        controller.hardwareKeyEnded(.keyboardLeftShift)
        controller.hardwareKeyEnded(.keyboardLeftControl)
    }

    /// Drives a real input-mode-change notification through the session's
    /// LanguageSyncCoordinator (fresh per call so its debounce can't interfere).
    private func changeInputLanguage() {
        let controller = loadedController()
        controller.startLanguageSyncIfNeeded()
        defer { controller.stopLanguageSync() }
        // The notification → decision step is covered by
        // testLanguageSwitchDecisionIgnoresFocusMovesAndUnknownLanguages.
        controller.languageSync?.onLanguageChange?("ru-RU")
    }

    private static func keyTexts(in view: UIView?) -> Set<String> {
        guard let view else { return [] }
        var result: Set<String> = []
        if let button = view as? KeyboardButton { result.insert(button.keyText) }
        for subview in view.subviews { result.formUnion(keyTexts(in: subview)) }
        return result
    }

    private static func onePixelImage() -> CGImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }.cgImage!
    }
}

private final class FakePan: UIPanGestureRecognizer {
    var fakeState: UIGestureRecognizer.State = .possible
    var fakeTranslation: CGPoint = .zero
    var fakeVelocity: CGPoint = .zero
    var fakeLocation: CGPoint = .zero
    var fakeTouches = 0

    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
    override var numberOfTouches: Int { fakeTouches }
    override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
    override func velocity(in view: UIView?) -> CGPoint { fakeVelocity }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
}

private final class FakeTap: UITapGestureRecognizer {
    var fakeLocation: CGPoint = .zero
    var fakeTouchLocations: [CGPoint] = []

    override var numberOfTouches: Int { fakeTouchLocations.count }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
    override func location(ofTouch touchIndex: Int, in view: UIView?) -> CGPoint {
        fakeTouchLocations[touchIndex]
    }
}

/// Records everything that crosses the ParsecService boundary.
private final class SettingsRecordingService: ParsecService {
    let adapterKind: ParsecAdapterKind = .fake
    var clientWidth: Float = 1024
    var clientHeight: Float = 768
    var hostWidth: Float = 1920
    var hostHeight: Float = 1080
    var mouseInfo = MouseInfo()
    var hostOSValue = -1
    var mediaReadiness: ParsecMediaReadiness = .notReady
    var mediaEvidence: ParsecMediaEvidence {
        ParsecMediaEvidence(readiness: mediaReadiness, videoStatus: nil, audioStatus: nil)
    }

    private let lock = NSLock()
    private var _keyboard: [String] = []
    private var _intents: [ParsecKeyboardMappingIntent] = []
    private var _mouseButtons: [String] = []
    private var _deltas: [String] = []
    private var _positions: [String] = []
    private var _wheel: [String] = []
    private var _videoConfigPushes = 0

    private func read<T>(_ value: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return value() }
    private func write(_ change: () -> Void) { lock.lock(); change(); lock.unlock() }

    var keyboard: [String] { read { _keyboard } }
    var intents: [ParsecKeyboardMappingIntent] { read { _intents } }
    var mouseButtons: [String] { read { _mouseButtons } }
    var deltas: [String] { read { _deltas } }
    var positions: [String] { read { _positions } }
    var wheel: [String] { read { _wheel } }
    var videoConfigPushes: Int { read { _videoConfigPushes } }

    func reset() {
        write {
            _keyboard = []; _intents = []; _mouseButtons = []
            _deltas = []; _positions = []; _wheel = []; _videoConfigPushes = 0
        }
    }

    func connect(_ peerID: String) -> RemoteStatus { .ok }
    func disconnect() {}
    func getStatus() -> RemoteStatus { .ok }
    func getStatusEx() -> RemoteClientStatus { RemoteClientStatus(status: .ok) }
    func setMuted(_ muted: Bool) {}
    func applyConfig() {}
    func sendUserData(type: ParsecUserDataType, message: Data) {}
    func updateHostVideoConfig() { write { _videoConfigPushes += 1 } }
    func setFrame(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) {}
    func renderGLFrame(timeout: UInt32) -> ParsecRenderFrameResult { .produced() }
    func sendMouseMessage(_ button: RemoteMouseButton, _ x: Int32, _ y: Int32, _ pressed: Bool) {
        write { _mouseButtons.append("positioned:\(button.rawValue):\(x):\(y):\(pressed)") }
    }
    func sendMouseClickMessage(_ button: RemoteMouseButton, _ pressed: Bool) {
        write { _mouseButtons.append("click:\(button.rawValue):\(pressed)") }
    }
    func sendMouseDelta(_ dx: Int32, _ dy: Int32) { write { _deltas.append("\(dx):\(dy)") } }
    func sendMousePosition(_ x: Int32, _ y: Int32) { write { _positions.append("\(x):\(y)") } }
    func sendKeyboardMessage(event: KeyBoardKeyEvent) {
        write {
            _keyboard.append("\(event.key.rawValue):\(event.isPressBegin)")
            _intents.append(event.mappingIntent)
        }
    }
    func sendVirtualKeyboardInput(text: String) {}
    func sendGameControllerButtonMessage(controllerId: UInt32, _ button: RemoteGamepadButton, pressed: Bool) {}
    func sendGameControllerAxisMessage(controllerId: UInt32, _ axis: RemoteGamepadAxis, _ value: Int16) {}
    func sendGameControllerUnplugMessage(controllerId: UInt32) {}
    func sendWheelMsg(x: Int32, y: Int32) { write { _wheel.append("\(x):\(y)") } }
}
