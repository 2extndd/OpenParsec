import XCTest
@testable import OpenParsec

final class ParsecClientTypesTests: XCTestCase {
    func testStatusClassifiesConnectionStates() {
        XCTAssertTrue(RemoteStatus.ok.isOK)
        XCTAssertTrue(RemoteStatus.connecting.isConnecting)
        XCTAssertTrue(RemoteStatus(rawValue: -6023).isFailure)
        XCTAssertFalse(RemoteStatus(rawValue: 5).isFailure)
    }

    func testInputCodesMatchTheParsecWireContract() {
        XCTAssertEqual(RemoteMouseButton.left.rawValue, 1)
        XCTAssertEqual(RemoteMouseButton.right.rawValue, 3)
        XCTAssertEqual(RemoteGamepadButton.a.rawValue, 0)
        XCTAssertEqual(RemoteGamepadButton.dpadRight.rawValue, 14)
        XCTAssertEqual(RemoteGamepadAxis.leftX.rawValue, 0)
        XCTAssertEqual(RemoteGamepadAxis.rightTrigger.rawValue, 5)
        XCTAssertEqual(RemoteKeyCode(rawValue: 4).rawValue, 4)
    }

    func testCParsecFacadeDelegatesLifecycleAndTracksPeer() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousPeer = CParsec.lastConnectedPeerID
        let service = RecordingParsecService(connectResult: .connecting)
        CParsec.parsecImpl = service
        defer {
            CParsec.parsecImpl = previousService
            CParsec.lastConnectedPeerID = previousPeer
        }

        XCTAssertEqual(CParsec.connect("peer-1"), .connecting)
        XCTAssertEqual(service.connectedPeerID, "peer-1")
        XCTAssertEqual(CParsec.lastConnectedPeerID, "peer-1")

        CParsec.disconnect()
        XCTAssertTrue(service.didDisconnect)
        XCTAssertNil(CParsec.lastConnectedPeerID)
    }

    func testAcceptedAsyncConnectRemainsConnectingUntilStatusPollIsHealthy() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousPeer = CParsec.lastConnectedPeerID
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        defer {
            _ = CParsec.disconnect()
            CParsec.parsecImpl = previousService
            CParsec.lastConnectedPeerID = previousPeer
        }

        XCTAssertEqual(CParsec.connect("peer-async"), .connecting)
        let generation = CParsec.sessionSnapshot.generation
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .connecting)
        XCTAssertEqual(CParsec.sessionSnapshot.transportStatus, .connecting)

        service.statusResult = .ok
        XCTAssertEqual(CParsec.getStatus(generation: generation), .ok)
        XCTAssertEqual(CParsec.sessionSnapshot.transportStatus, .ok)
    }

    func testCParsecFacadePublishesTransportAndMediaReadiness() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousTracker = CParsec.sessionTracker
        let service = RecordingParsecService(connectResult: .connecting)
        let tracker = makeTracker()
        CParsec.parsecImpl = service
        CParsec.sessionTracker = tracker
        defer {
            CParsec.parsecImpl = previousService
            CParsec.sessionTracker = previousTracker
        }

        XCTAssertEqual(CParsec.connect("peer-1"), .connecting)
        let generation = CParsec.sessionSnapshot.generation
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .connecting)

        service.statusResult = .ok
        service.mediaReadiness = .ready
        XCTAssertEqual(CParsec.getStatus(generation: generation), .ok)

        XCTAssertEqual(CParsec.sessionSnapshot.phase, .interactive)
        XCTAssertEqual(CParsec.sessionSnapshot.media, .ready)
        XCTAssertEqual(CParsec.sessionSnapshot.transportStatus, .ok)
    }

    func testCParsecFacadeRejectsStatusFromAnOlderGeneration() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousTracker = CParsec.sessionTracker
        let service = RecordingParsecService(connectResult: .connecting)
        let tracker = makeTracker()
        CParsec.parsecImpl = service
        CParsec.sessionTracker = tracker
        defer {
            CParsec.parsecImpl = previousService
            CParsec.sessionTracker = previousTracker
        }

        _ = CParsec.connect("peer-1")
        let staleGeneration = CParsec.sessionSnapshot.generation
        _ = CParsec.connect("peer-2", intent: .reconnect)
        let currentGeneration = CParsec.sessionSnapshot.generation

        service.statusResult = RemoteStatus(rawValue: -6023)
        XCTAssertEqual(CParsec.getStatus(generation: staleGeneration).rawValue, -6023)

        XCTAssertEqual(CParsec.sessionSnapshot.generation, currentGeneration)
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .reconnecting)
        XCTAssertNil(CParsec.sessionSnapshot.lastFailure)
    }

    func testRenderEvidenceFromOlderGenerationCannotMarkReplacementReady() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousTracker = CParsec.sessionTracker
        let service = RecordingParsecService(connectResult: .connecting)
        let tracker = makeTracker()
        CParsec.parsecImpl = service
        CParsec.sessionTracker = tracker
        defer {
            CParsec.parsecImpl = previousService
            CParsec.sessionTracker = previousTracker
        }

        _ = CParsec.connect("peer-old")
        let staleGeneration = CParsec.sessionSnapshot.generation
        service.renderHook = {
            _ = tracker.beginConnect(intent: .reconnect, adapter: .fake)
            service.mediaReadiness = .ready
        }

        XCTAssertEqual(CParsec.renderGLFrame(timeout: 16), .produced())

        XCTAssertGreaterThan(CParsec.sessionSnapshot.generation, staleGeneration)
        XCTAssertEqual(CParsec.sessionSnapshot.media, .notReady)
        XCTAssertNotEqual(CParsec.sessionSnapshot.phase, .interactive)
    }

    func testConcurrentFacadeDisconnectDoesNotCallAdapterTwice() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousTracker = CParsec.sessionTracker
        let service = RecordingParsecService(connectResult: .connecting)
        CParsec.parsecImpl = service
        CParsec.sessionTracker = makeTracker()
        defer {
            CParsec.parsecImpl = previousService
            CParsec.sessionTracker = previousTracker
        }

        _ = CParsec.connect("peer-1")
        let generation = CParsec.sessionSnapshot.generation
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "openparsec.disconnect-test", attributes: .concurrent)
        for _ in 0..<20 {
            group.enter()
            queue.async {
                CParsec.disconnect(reason: .backgroundExpired, generation: generation)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(service.disconnectCount, 1)
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .disconnected)
        XCTAssertEqual(CParsec.sessionSnapshot.disconnectReason, .backgroundExpired)
    }

    func testFacadeReportsBackgroundAndForegroundOnTheActiveGeneration() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousTracker = CParsec.sessionTracker
        let service = RecordingParsecService(connectResult: .connecting)
        CParsec.parsecImpl = service
        CParsec.sessionTracker = makeTracker()
        defer {
            CParsec.parsecImpl = previousService
            CParsec.sessionTracker = previousTracker
        }

        _ = CParsec.connect("peer-1")
        let generation = CParsec.sessionSnapshot.generation
        service.statusResult = .ok
        service.mediaReadiness = .ready
        _ = CParsec.getStatus(generation: generation)

        CParsec.enterBackground(generation: generation)
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .background)
        CParsec.enterBackgroundGrace(generation: generation)
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .backgroundGrace)

        CParsec.resumeForeground(generation: generation)
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .interactive)
    }

    private func makeTracker() -> ParsecSessionTracker {
        ParsecSessionTracker(
            failureStore: ClientTypesFailureStore(),
            logger: ClientTypesTransitionLogger()
        )
    }

    func testNativePointerStartsUnlockedWithHostCursorFallback() {
        let behavior = ParsecPointerBehavior(
            mode: .native,
            nativePointerActive: false
        )

        XCTAssertFalse(behavior.prefersPointerLocked)
        XCTAssertEqual(behavior.inputRoute, .absolute)
        XCTAssertEqual(behavior.cursorOwner, .host)
        XCTAssertTrue(behavior.showsHostCursor)
        XCTAssertFalse(behavior.showsLocalCursor)
    }

    func testNativeHoverTransfersCursorOwnershipToSystemPointer() {
        let behavior = ParsecPointerBehavior(
            mode: .native,
            nativePointerActive: true
        )

        XCTAssertFalse(behavior.prefersPointerLocked)
        XCTAssertEqual(behavior.inputRoute, .absolute)
        XCTAssertEqual(behavior.cursorOwner, .system)
        XCTAssertFalse(behavior.showsHostCursor)
        XCTAssertFalse(behavior.showsLocalCursor)
    }

    func testCapturedPointerLocksAndUsesLocalRelativeCursor() {
        let behavior = ParsecPointerBehavior(
            mode: .captured,
            nativePointerActive: true
        )

        XCTAssertTrue(behavior.prefersPointerLocked)
        XCTAssertEqual(behavior.inputRoute, .relative)
        XCTAssertEqual(behavior.cursorOwner, .local)
        XCTAssertFalse(behavior.showsHostCursor)
        XCTAssertTrue(behavior.showsLocalCursor)
        XCTAssertEqual(
            behavior.digest,
            "mode=captured lock=true route=relative cursor=local"
        )
    }

    @MainActor
    func testViewControllerPointerLockFollowsPresentationMode() {
        let previousMode = SettingsHandler.pointerPresentationMode
        defer { SettingsHandler.pointerPresentationMode = previousMode }
        let controller = ParsecViewController()

        // Edge gestures (iPad Dock / home swipe) are deferred for the whole
        // session in both modes, and released while an overlay is open.
        SettingsHandler.pointerPresentationMode = .native
        XCTAssertFalse(controller.prefersPointerLocked)
        XCTAssertEqual(controller.preferredScreenEdgesDeferringSystemGestures, .all)

        SettingsHandler.pointerPresentationMode = .captured
        XCTAssertTrue(controller.prefersPointerLocked)
        XCTAssertEqual(controller.preferredScreenEdgesDeferringSystemGestures, .all)

        ParsecViewController.sessionOverlayActive = true
        defer { ParsecViewController.sessionOverlayActive = false }
        XCTAssertFalse(controller.prefersPointerLocked)
        XCTAssertEqual(controller.preferredScreenEdgesDeferringSystemGestures, [])
    }

    func testPointerMovementAppliesSensitivityAndAcceleration() {
        XCTAssertEqual(
            ParsecPointerTransform.movement(
                x: 3,
                y: 4,
                sensitivity: 1,
                acceleration: 1
            ),
            ParsecInputDelta(x: 6, y: 8)
        )
        XCTAssertEqual(
            ParsecPointerTransform.movement(
                x: 3,
                y: 4,
                sensitivity: -1,
                acceleration: -1
            ),
            ParsecInputDelta(x: 0, y: 0)
        )
    }

    func testGenerationRequestGateClaimsEachReplacementExactlyOnce() {
        var gate = ParsecGenerationRequestGate()

        XCTAssertTrue(gate.claim(generation: 2))
        XCTAssertFalse(gate.claim(generation: 2))
        XCTAssertTrue(gate.claim(generation: 3))
        XCTAssertFalse(gate.claim(generation: 3))
    }

    func testScrollTransformPreservesAxesAndNaturalDirection() {
        XCTAssertEqual(
            ParsecPointerTransform.scroll(
                x: 2,
                y: -3,
                sensitivity: 0.5,
                natural: true
            ),
            ParsecInputDelta(x: 1, y: -1.5)
        )
        XCTAssertEqual(
            ParsecPointerTransform.scroll(
                x: 2,
                y: -3,
                sensitivity: 0.5,
                natural: false
            ),
            ParsecInputDelta(x: -1, y: 1.5)
        )
    }

    func testDeltaAccumulatorRetainsSubPixelRemainder() {
        var accumulator = ParsecDeltaAccumulator()

        XCTAssertNil(accumulator.consume(ParsecInputDelta(x: 0.4, y: 0)))
        XCTAssertEqual(
            accumulator.consume(ParsecInputDelta(x: 0.4, y: 0)),
            ParsecIntegerInputDelta(x: 1, y: 0)
        )
        XCTAssertEqual(accumulator.x, -0.2, accuracy: 0.0001)
        XCTAssertEqual(
            accumulator.consume(ParsecInputDelta(x: -0.4, y: 0)),
            ParsecIntegerInputDelta(x: -1, y: 0)
        )
        XCTAssertEqual(accumulator.x, 0.4, accuracy: 0.0001)

        accumulator.reset()
        XCTAssertEqual(accumulator, ParsecDeltaAccumulator())
    }

    func testMouseButtonLatchRejectsDuplicatesAndReleasesAll() {
        var latch = ParsecMouseButtonLatch()

        XCTAssertTrue(latch.update(.left, pressed: true))
        XCTAssertFalse(latch.update(.left, pressed: true))
        XCTAssertTrue(latch.update(.right, pressed: true))
        XCTAssertEqual(latch.digest, "pressed=2")
        XCTAssertFalse(latch.update(.middle, pressed: false))
        XCTAssertEqual(latch.releaseAll(), [.left, .right])
        XCTAssertEqual(latch.digest, "pressed=0")
        XCTAssertTrue(latch.releaseAll().isEmpty)
    }

    func testKeyboardStateForwardsRepeatAndAcceptsOneRelease() {
        var keyboard = ParsecKeyboardStateMachine()
        let letterA = RemoteKeyCode(rawValue: 4)

        XCTAssertTrue(keyboard.beginGeneration(7).isEmpty)
        XCTAssertEqual(keyboard.press(letterA), .pressed)
        XCTAssertEqual(keyboard.press(letterA), .repeated)
        XCTAssertEqual(keyboard.press(letterA), .repeated)
        XCTAssertEqual(keyboard.snapshot.pressedCount, 1)
        XCTAssertEqual(keyboard.snapshot.repeatCount, 2)
        XCTAssertEqual(keyboard.release(letterA), .released)
        XCTAssertEqual(keyboard.release(letterA), .ignored)
        XCTAssertEqual(
            keyboard.snapshot,
            ParsecKeyboardSnapshot(
                generation: 7,
                pressedCount: 0,
                repeatCount: 2,
                lastReleaseReason: .normal
            )
        )
    }

    func testKeyboardReleaseAllIsDeterministicAcrossKeyClasses() {
        var keyboard = ParsecKeyboardStateMachine()
        let leftControl = RemoteKeyCode(rawValue: 224)
        let rightShift = RemoteKeyCode(rawValue: 229)
        let rightArrow = RemoteKeyCode(rawValue: 79)
        let functionKey = RemoteKeyCode(rawValue: 58)
        _ = keyboard.beginGeneration(11)

        XCTAssertEqual(keyboard.press(rightShift), .pressed)
        XCTAssertEqual(keyboard.press(functionKey), .pressed)
        XCTAssertEqual(keyboard.press(leftControl), .pressed)
        XCTAssertEqual(keyboard.press(rightArrow), .pressed)
        XCTAssertEqual(
            keyboard.releaseAll(reason: .cancelled),
            [functionKey, rightArrow, leftControl, rightShift]
        )
        XCTAssertEqual(keyboard.snapshot.pressedCount, 0)
        XCTAssertEqual(keyboard.snapshot.lastReleaseReason, .cancelled)
    }

    func testKeyboardGenerationResetClearsHeldKeysAndRepeatCount() {
        var keyboard = ParsecKeyboardStateMachine()
        let key = RemoteKeyCode(rawValue: 40)
        _ = keyboard.beginGeneration(1)
        _ = keyboard.press(key)
        _ = keyboard.press(key)

        XCTAssertEqual(keyboard.beginGeneration(2), [key])
        XCTAssertEqual(
            keyboard.snapshot,
            ParsecKeyboardSnapshot(
                generation: 2,
                pressedCount: 0,
                repeatCount: 0,
                lastReleaseReason: .reconnect
            )
        )
        XCTAssertFalse(keyboard.digestContainsInputContent)
    }

    // MARK: - Gamepad state machine (S11)

    func testGamepadButtonPressReleaseIsBalancedAndIgnoresOrphans() {
        var pad = ParsecGamepadStateMachine()
        XCTAssertEqual(pad.button(.a, pressed: true, controllerId: 1), .pressed)
        XCTAssertEqual(pad.button(.a, pressed: true, controllerId: 1), .ignored)
        XCTAssertEqual(pad.snapshot.pressedCount, 1)
        XCTAssertEqual(pad.button(.a, pressed: false, controllerId: 1), .released)
        XCTAssertEqual(pad.button(.a, pressed: false, controllerId: 1), .ignored)
        XCTAssertEqual(pad.snapshot.pressedCount, 0)
        XCTAssertEqual(pad.snapshot.lastReleaseReason, .normal)
    }

    func testGamepadUnsupportedButtonIsCountedNotForwarded() {
        var pad = ParsecGamepadStateMachine()
        XCTAssertFalse(ParsecGamepadButtonSupport.isSupported(.guide))
        XCTAssertTrue(ParsecGamepadButtonSupport.isSupported(.a))
        XCTAssertEqual(pad.button(.guide, pressed: true, controllerId: 1), .ignored)
        XCTAssertEqual(pad.button(.guide, pressed: false, controllerId: 1), .ignored)
        XCTAssertEqual(pad.snapshot.pressedCount, 0)
        XCTAssertEqual(pad.snapshot.unsupportedCount, 2)
    }

    func testGamepadAxisTracksNonNeutralAndClearsOnZero() {
        var pad = ParsecGamepadStateMachine()
        pad.axis(.leftX, value: 1000, controllerId: 1)
        pad.axis(.leftY, value: -1000, controllerId: 1)
        XCTAssertEqual(pad.snapshot.nonNeutralAxisCount, 2)
        pad.axis(.leftX, value: 0, controllerId: 1)
        XCTAssertEqual(pad.snapshot.nonNeutralAxisCount, 1)
        pad.axis(.leftY, value: 0, controllerId: 1)
        XCTAssertEqual(pad.snapshot.nonNeutralAxisCount, 0)
    }

    func testGamepadReleaseAllReturnsOrderedButtonsAndAxesThenClears() {
        var pad = ParsecGamepadStateMachine()
        _ = pad.button(.rightShoulder, pressed: true, controllerId: 1)
        _ = pad.button(.a, pressed: true, controllerId: 1)
        pad.axis(.rightTrigger, value: 500, controllerId: 1)
        pad.axis(.leftX, value: 500, controllerId: 1)

        let released = pad.releaseAll(reason: .background)
        XCTAssertEqual(released.buttons.map { $0.1 }, [.a, .rightShoulder])
        XCTAssertEqual(released.axes.map { $0.1 }, [.leftX, .rightTrigger])
        XCTAssertTrue(released.buttons.allSatisfy { $0.0 == 1 })
        XCTAssertEqual(pad.snapshot.pressedCount, 0)
        XCTAssertEqual(pad.snapshot.nonNeutralAxisCount, 0)
        XCTAssertEqual(pad.snapshot.lastReleaseReason, .background)
    }

    func testGamepadReleaseControllerOnlyClearsThatController() {
        var pad = ParsecGamepadStateMachine()
        _ = pad.button(.a, pressed: true, controllerId: 1)
        _ = pad.button(.b, pressed: true, controllerId: 2)
        pad.axis(.leftX, value: 500, controllerId: 1)

        let released = pad.releaseController(1)
        XCTAssertEqual(released.buttons, [.a])
        XCTAssertEqual(released.axes, [.leftX])
        XCTAssertEqual(pad.snapshot.pressedCount, 1)
        XCTAssertEqual(pad.snapshot.lastReleaseReason, .controllerDisconnected)
    }

    func testGamepadGenerationResetReleasesHeldStateAndSetsReconnectReason() {
        var pad = ParsecGamepadStateMachine()
        _ = pad.beginGeneration(1)
        _ = pad.button(.a, pressed: true, controllerId: 1)
        pad.axis(.leftX, value: 700, controllerId: 1)

        let released = pad.beginGeneration(2)
        XCTAssertEqual(released.buttons.map { $0.1 }, [.a])
        XCTAssertEqual(released.axes.map { $0.1 }, [.leftX])
        XCTAssertEqual(pad.snapshot.generation, 2)
        XCTAssertEqual(pad.snapshot.pressedCount, 0)
        XCTAssertEqual(pad.snapshot.nonNeutralAxisCount, 0)
        XCTAssertEqual(pad.snapshot.lastReleaseReason, .reconnect)
    }

    func testGamepadSnapshotDigestExposesOnlyCounts() {
        var pad = ParsecGamepadStateMachine()
        _ = pad.beginGeneration(3)
        _ = pad.button(.a, pressed: true, controllerId: 1)
        pad.axis(.leftX, value: 900, controllerId: 1)
        let digest = pad.snapshot.digest
        XCTAssertEqual(
            digest,
            "generation=3 pressed=1 axes=1 unsupported=0 release=reconnect"
        )
    }

    // MARK: - Settings contract (S12)

    /// Derived from the canonical registry so adding a persisted setting has
    /// one source of truth rather than a fourth test-only key list.
    private static let persistedSettingKeys = Set(
        ParsecSettingID.allCases.map(\.rawValue)
    )

    func testCanonicalSettingsRegistryOwnsKeysAndDefaults() {
        XCTAssertEqual(ParsecSettingID.allCases.count, 30)
        XCTAssertEqual(
            Set(ParsecSettingsContract.descriptors.map(\.id)),
            Set(ParsecSettingID.allCases)
        )
        XCTAssertEqual(
            ParsecSettingsContract.descriptor(for: .syncKeyboardLayout)?.defaultValue,
            ParsecSettingDefault(SettingsDefaults.syncKeyboardLayout)
        )
        XCTAssertEqual(
            ParsecSettingsContract.descriptor(for: .windowsKeyboardMode)?.defaultValue,
            ParsecSettingDefault(SettingsDefaults.windowsKeyboardMode)
        )
    }

    func testLiveSettingChangePublishesOnlyCanonicalID() {
        var observed: ParsecSettingChange?
        let token = NotificationCenter.default.addObserver(
            forName: .parsecSettingDidChange,
            object: nil,
            queue: nil
        ) { notification in
            observed = notification.object as? ParsecSettingChange
        }
        defer { NotificationCenter.default.removeObserver(token) }

        SettingsHandler.notifyChanged(.syncKeyboardLayout)

        XCTAssertEqual(observed, ParsecSettingChange(id: .syncKeyboardLayout))
    }

    // Every session used to leak its controller (strong back-references from
    // the GLK surface, touch/gamepad controllers and the updateImage closure),
    // leaving N live render loops that all resumed on foreground.
    @MainActor
    func testSessionViewControllerIsReleased() {
        weak var weakController: ParsecViewController?
        autoreleasepool {
            let controller = ParsecViewController()
            controller.loadViewIfNeeded()
            weakController = controller
        }
        XCTAssertNil(weakController)
    }

    @MainActor
    func testViewControllerAppliesLiveKeyboardSettingChanges() {
        let previousSync = SettingsHandler.syncKeyboardLayout
        let previousToolbarMode = SettingsHandler.hostShortcutToolbarMode
        let previousCapture = SettingsHandler.captureSystemKeys
        let previousFPS = SettingsHandler.preferredFramesPerSecond
        defer {
            SettingsHandler.syncKeyboardLayout = previousSync
            SettingsHandler.hostShortcutToolbarMode = previousToolbarMode
            SettingsHandler.captureSystemKeys = previousCapture
            SettingsHandler.preferredFramesPerSecond = previousFPS
        }

        SettingsHandler.syncKeyboardLayout = false
        SettingsHandler.hostShortcutToolbarMode = .off
        SettingsHandler.captureSystemKeys = false
        let controller = ParsecViewController()
        controller.loadViewIfNeeded()
        // The hidden input field is started on appear regardless of the sync
        // setting (it keeps hardware keys arriving); the setting only gates
        // the hotkey inside the coordinator, so toggling never tears it down.
        controller.startLanguageSyncIfNeeded()
        let coordinator = controller.languageSync
        XCTAssertNotNil(coordinator)
        SettingsHandler.syncKeyboardLayout = true
        SettingsHandler.notifyChanged(.syncKeyboardLayout)
        SettingsHandler.syncKeyboardLayout = false
        SettingsHandler.notifyChanged(.syncKeyboardLayout)
        XCTAssertTrue(controller.languageSync === coordinator)

        _ = controller.inputAccessoryView
        XCTAssertNotNil(controller.keyboardAccessoriesView)
        SettingsHandler.hostShortcutToolbarMode = .macOS
        SettingsHandler.notifyChanged(.hostShortcutToolbarMode)
        XCTAssertNil(controller.keyboardAccessoriesView)

        XCTAssertTrue(controller.keyCommands?.isEmpty ?? true)
        SettingsHandler.captureSystemKeys = true
        SettingsHandler.notifyChanged(.captureSystemKeys)
        XCTAssertFalse(controller.keyCommands?.isEmpty ?? true)

        SettingsHandler.preferredFramesPerSecond = 60
        SettingsHandler.notifyChanged(.preferredFramesPerSecond)
        XCTAssertEqual(
            (controller.glkView as? ParsecGLKViewController)?
                .glkViewController.preferredFramesPerSecond,
            60
        )
    }

    func testSettingsContractMatchesPersistedKeysTwoWay() {
        let contractKeys = Set(ParsecSettingsContract.descriptors.map { $0.key })
        let realKeys = Self.persistedSettingKeys
        XCTAssertEqual(
            contractKeys.subtracting(realKeys),
            [],
            "Contract names keys with no matching @AppStorage property (dead settings)"
        )
        XCTAssertEqual(
            realKeys.subtracting(contractKeys),
            [],
            "Persisted @AppStorage keys are missing a contract entry"
        )
        // No duplicate descriptors for the same key.
        XCTAssertEqual(
            contractKeys.count,
            ParsecSettingsContract.descriptors.count,
            "Duplicate contract entries for a key"
        )
        XCTAssertEqual(ParsecSettingsContract.coverageCount, 30)
    }

    func testSettingsContractClassificationsAreInternallyConsistent() {
        for descriptor in ParsecSettingsContract.descriptors {
            switch descriptor.kind {
            case .sessionSavedState:
                XCTAssertFalse(
                    descriptor.hasUIControl,
                    "\(descriptor.key): session-saved state must not claim a UI control"
                )
                // The saved* session keys are restored at connect; other
                // headless config settings (e.g. bitrate) apply on reconnect.
                if descriptor.key.hasPrefix("saved") {
                    XCTAssertEqual(
                        descriptor.application, .restoredOnConnect,
                        "\(descriptor.key): saved session state should be restored-on-connect"
                    )
                }
            case .userVisibleControl:
                XCTAssertTrue(
                    descriptor.hasUIControl,
                    "\(descriptor.key): user-visible control must have a UI control"
                )
            }
        }
        // The dead legacy key must not appear in the contract.
        XCTAssertNil(ParsecSettingsContract.descriptor(forKey: "windowsHostKeyboardRemap"))
    }

    func testWindowsKeyboardRemapMigrationStillSeedsModeFromLegacyKey() {
        let suiteName = "contract-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Simulate a pre-upgrade install with the legacy remap enabled and no
        // new mode key.
        defaults.set(true, forKey: "windowsHostKeyboardRemap")
        XCTAssertNil(defaults.object(forKey: "windowsKeyboardMode"))
        // Mirror the migration logic against the isolated suite.
        if defaults.object(forKey: "windowsKeyboardMode") == nil {
            let legacyEnabled = defaults.bool(forKey: "windowsHostKeyboardRemap")
            defaults.set(
                (legacyEnabled ? WindowsKeyboardMode.commandAsControl : .direct).rawValue,
                forKey: "windowsKeyboardMode"
            )
        }
        XCTAssertEqual(
            defaults.integer(forKey: "windowsKeyboardMode"),
            WindowsKeyboardMode.commandAsControl.rawValue
        )
        // Legacy key is preserved (non-destructive migration).
        XCTAssertTrue(defaults.bool(forKey: "windowsHostKeyboardRemap"))
    }

    func testHostShortcutToolbarModeMigratesLegacyBooleanCombinations() {
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.migrate(
                showMac: nil,
                showWindows: nil
            ),
            .automatic
        )
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.migrate(
                showMac: true,
                showWindows: true
            ),
            .both
        )
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.migrate(
                showMac: true,
                showWindows: false
            ),
            .macOS
        )
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.migrate(
                showMac: false,
                showWindows: true
            ),
            .windows
        )
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.migrate(
                showMac: false,
                showWindows: false
            ),
            .off
        )
    }

    func testPointerPresentationMigrationPreservesLegacyLocalOverlay() {
        let suiteName = "pointer-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "localCursorOverlay")

        SettingsHandler.migratePointerPresentationModeIfNeeded(
            defaults: defaults
        )

        XCTAssertEqual(
            defaults.integer(
                forKey: ParsecSettingID.pointerPresentationMode.rawValue
            ),
            PointerPresentationMode.captured.rawValue
        )
        XCTAssertNil(defaults.object(forKey: "localCursorOverlay"))
    }

    func testHostShortcutToolbarMigrationPersistsModeAndRemovesLegacyKeys() {
        let suiteName = "toolbar-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "showMacShortcutButtons")
        defaults.set(false, forKey: "showWindowsShortcutButtons")

        SettingsHandler.migrateHostShortcutToolbarIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.integer(
                forKey: ParsecSettingID.hostShortcutToolbarMode.rawValue
            ),
            HostShortcutToolbarMode.macOS.rawValue
        )
        XCTAssertNil(defaults.object(forKey: "showMacShortcutButtons"))
        XCTAssertNil(defaults.object(forKey: "showWindowsShortcutButtons"))
    }

    func testHostOSMapsOnlyThePhysicallyConfirmedMacValue() {
        XCTAssertEqual(HostOS.from(2), .macos)
        XCTAssertEqual(HostOS.from(1), .windows)
        XCTAssertEqual(HostOS.from(0), .windows)
        XCTAssertEqual(HostOS.from(-1), .unknown)
    }

    func testHostShortcutToolbarModeResolvesAutomaticHostFallbacks() {
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.visibility(
                mode: .automatic,
                host: .macos
            ),
            ParsecHostShortcutVisibility(showMac: true, showWindows: false)
        )
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.visibility(
                mode: .automatic,
                host: .windows
            ),
            ParsecHostShortcutVisibility(showMac: false, showWindows: true)
        )
        XCTAssertEqual(
            ParsecHostShortcutToolbarPolicy.visibility(
                mode: .automatic,
                host: .unknown
            ),
            ParsecHostShortcutVisibility(showMac: true, showWindows: true)
        )
    }

    func testPoorNetworkPresetAppliesCascadeAndStaysOverridable() {
        // Snapshot the real settings so the test does not leak into others.
        let prevFps = SettingsHandler.preferredFramesPerSecond
        let prevDecoder = SettingsHandler.decoder
        let prevOverlay = SettingsHandler.noOverlay
        let prevCompat = SettingsHandler.decoderCompatibility
        let prevBitrate = SettingsHandler.bitrate
        defer {
            SettingsHandler.preferredFramesPerSecond = prevFps
            SettingsHandler.decoder = prevDecoder
            SettingsHandler.noOverlay = prevOverlay
            SettingsHandler.decoderCompatibility = prevCompat
            SettingsHandler.bitrate = prevBitrate
        }

        // Start from a non-profile state.
        SettingsHandler.preferredFramesPerSecond = 120
        SettingsHandler.decoder = .h264
        SettingsHandler.noOverlay = false
        SettingsHandler.decoderCompatibility = true
        SettingsHandler.bitrate = 50

        let prevResolution = SettingsHandler.resolution
        defer { SettingsHandler.resolution = prevResolution }
        SettingsHandler.resolution = .client

        SettingsHandler.applyPoorNetworkPreset()

        // Local display refresh is not a network knob: left alone.
        XCTAssertEqual(SettingsHandler.preferredFramesPerSecond, 120)
        XCTAssertEqual(SettingsHandler.resolution, .r1280x720_16_9)
        XCTAssertEqual(SettingsHandler.decoder, .h265)
        XCTAssertFalse(SettingsHandler.noOverlay, "the preset must not hide the session menu")
        XCTAssertFalse(SettingsHandler.decoderCompatibility)
        XCTAssertEqual(SettingsHandler.bitrate, 5)

        // Each knob remains individually overridable after the cascade.
        SettingsHandler.preferredFramesPerSecond = 60
        SettingsHandler.bitrate = 20
        XCTAssertEqual(SettingsHandler.preferredFramesPerSecond, 60)
        XCTAssertEqual(SettingsHandler.bitrate, 20)
    }

    func testSettingRoundTripsThroughPersistence() {
        let prevScroll = SettingsHandler.scrollSensitivity
        let prevNatural = SettingsHandler.naturalScrolling
        defer {
            SettingsHandler.scrollSensitivity = prevScroll
            SettingsHandler.naturalScrolling = prevNatural
        }
        SettingsHandler.scrollSensitivity = 2.5
        SettingsHandler.naturalScrolling = false
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "scrollSensitivity"),
            2.5,
            accuracy: 0.0001
        )
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "naturalScrolling"))
        XCTAssertEqual(SettingsHandler.scrollSensitivity, 2.5, accuracy: 0.0001)
        XCTAssertFalse(SettingsHandler.naturalScrolling)
    }

    func testHostSpecificSettingsAreClassifiedAndNotApplicableCrossHost() {
        // Windows-only setting: applicable to Windows, not macOS.
        XCTAssertTrue(ParsecSettingsContract.isApplicable("windowsKeyboardMode", to: .windows))
        XCTAssertFalse(ParsecSettingsContract.isApplicable("windowsKeyboardMode", to: .macOS))
        XCTAssertTrue(ParsecSettingsContract.isApplicable("hostShortcutToolbarMode", to: .windows))
        XCTAssertTrue(ParsecSettingsContract.isApplicable("hostShortcutToolbarMode", to: .macOS))

        // macOS-only trigger macros remain unavailable to Windows hosts.
        for key in ["ctrlShiftEmulatesCmdSpace", "backtickEmulatesCmdSpace"] {
            XCTAssertEqual(ParsecSettingsContract.descriptor(forKey: key)?.host, .macOS, key)
            XCTAssertTrue(ParsecSettingsContract.isApplicable(key, to: .macOS), key)
            XCTAssertFalse(ParsecSettingsContract.isApplicable(key, to: .windows), key)
        }

        // Host-agnostic setting: applicable to both.
        XCTAssertTrue(ParsecSettingsContract.isApplicable("scrollSensitivity", to: .macOS))
        XCTAssertTrue(ParsecSettingsContract.isApplicable("scrollSensitivity", to: .windows))

        // Unknown key: not applicable to anything.
        XCTAssertFalse(ParsecSettingsContract.isApplicable("nonexistent", to: .windows))
    }

    // MARK: - Resource ledger (S13)

    func testResourceLedgerBalancedBufferGetFreeIsZeroOutstanding() {
        var ledger = ParsecResourceLedger()
        ledger.acquireBuffer()
        ledger.acquireBuffer()
        XCTAssertEqual(ledger.outstandingBuffers, 2)
        XCTAssertFalse(ledger.isBalanced)
        ledger.freeBuffer()
        ledger.freeBuffer()
        XCTAssertEqual(ledger.outstandingBuffers, 0)
        XCTAssertTrue(ledger.isBalanced)
    }

    func testResourceLedgerDetectsUnfreedBuffer() {
        var ledger = ParsecResourceLedger()
        ledger.acquireBuffer()
        ledger.acquireBuffer()
        ledger.freeBuffer()
        XCTAssertEqual(ledger.outstandingBuffers, 1)
        XCTAssertFalse(ledger.isBalanced)
    }

    func testResourceLedgerGenerationOnlyAdvancesMonotonically() {
        var ledger = ParsecResourceLedger()
        XCTAssertTrue(ledger.advanceGeneration(to: 1))
        XCTAssertTrue(ledger.advanceGeneration(to: 2))
        // A regressed or duplicated generation is rejected.
        XCTAssertFalse(ledger.advanceGeneration(to: 2))
        XCTAssertFalse(ledger.advanceGeneration(to: 1))
        XCTAssertEqual(ledger.pollGeneration, 2)
    }

    func testResourceLedgerDetectsUnremovedObserverAndTimer() {
        var ledger = ParsecResourceLedger()
        ledger.addObserver()
        ledger.addTimer()
        ledger.addObserver()
        ledger.removeObserver()
        ledger.removeTimer()
        XCTAssertEqual(ledger.activeObservers, 1)
        XCTAssertEqual(ledger.activeTimers, 0)
        XCTAssertFalse(ledger.isBalanced)
        ledger.removeObserver()
        XCTAssertTrue(ledger.isBalanced)
    }

    func testResourceLedgerDigestIsContentFree() {
        var ledger = ParsecResourceLedger()
        ledger.advanceGeneration(to: 3)
        ledger.acquireBuffer()
        ledger.addTimer()
        ledger.recordConnectCycle()
        XCTAssertEqual(
            ledger.digest,
            "gen=3 buffers=1 timers=1 observers=0 cycles=1"
        )
    }

    func testWindowsKeyboardMappingIsDirectOrOneWayCommandAsControl() {
        let leftCommand = RemoteKeyCode(rawValue: 227)
        let rightCommand = RemoteKeyCode(rawValue: 231)
        let leftControl = RemoteKeyCode(rawValue: 224)
        let rightControl = RemoteKeyCode(rawValue: 228)

        XCTAssertEqual(
            ParsecWindowsKeyboardMapping.map(
                leftCommand,
                mode: .direct,
                intent: .configured
            ),
            leftCommand
        )
        XCTAssertEqual(
            ParsecWindowsKeyboardMapping.map(
                leftCommand,
                mode: .commandAsControl,
                intent: .configured
            ),
            leftControl
        )
        XCTAssertEqual(
            ParsecWindowsKeyboardMapping.map(
                rightCommand,
                mode: .commandAsControl,
                intent: .configured
            ),
            rightControl
        )
        XCTAssertEqual(
            ParsecWindowsKeyboardMapping.map(
                leftControl,
                mode: .commandAsControl,
                intent: .configured
            ),
            leftControl
        )
        XCTAssertEqual(
            ParsecWindowsKeyboardMapping.map(
                leftCommand,
                mode: .commandAsControl,
                intent: .raw
            ),
            leftCommand
        )
    }

    func testKeyboardMappingLatchKeepsPressAndReleaseInTheSameMode() {
        var latch = ParsecKeyboardMappingLatch()
        let command = RemoteKeyCode(rawValue: 227)
        let control = RemoteKeyCode(rawValue: 224)

        XCTAssertEqual(
            latch.map(
                command,
                pressed: true,
                mode: .commandAsControl,
                intent: .configured
            ),
            control
        )
        XCTAssertEqual(
            latch.map(
                command,
                pressed: false,
                mode: .direct,
                intent: .configured
            ),
            control
        )
        XCTAssertTrue(latch.isAtRest)
    }

    func testKeyboardMappingLatchKeepsPhysicalAndVirtualLanesIndependent() {
        var latch = ParsecKeyboardMappingLatch()
        let command = RemoteKeyCode(rawValue: 227)
        let control = RemoteKeyCode(rawValue: 224)

        XCTAssertEqual(
            latch.map(
                command,
                pressed: true,
                mode: .commandAsControl,
                intent: .configured,
                source: .event
            ),
            control
        )
        XCTAssertEqual(
            latch.map(
                command,
                pressed: true,
                mode: .direct,
                intent: .configured,
                source: .virtualToggle
            ),
            command
        )
        XCTAssertEqual(
            latch.map(
                command,
                pressed: false,
                mode: .direct,
                intent: .configured,
                source: .event
            ),
            control
        )
        XCTAssertEqual(
            latch.map(
                command,
                pressed: false,
                mode: .commandAsControl,
                intent: .configured,
                source: .virtualToggle
            ),
            command
        )
        XCTAssertTrue(latch.isAtRest)
    }

    func testWindowsShortcutCatalogProvidesRawAlternatives() {
        XCTAssertEqual(
            ParsecWindowsShortcutCatalog.descriptor(for: .appSwitcher),
            ParsecWindowsShortcutDescriptor(
                action: .appSwitcher,
                route: .explicitMacro,
                chord: [
                    RemoteKeyCode(rawValue: 226),
                    RemoteKeyCode(rawValue: 43)
                ],
                mappingIntent: .raw
            )
        )
        XCTAssertEqual(
            ParsecWindowsShortcutCatalog.descriptor(for: .startMenu),
            ParsecWindowsShortcutDescriptor(
                action: .startMenu,
                route: .explicitMacro,
                chord: [RemoteKeyCode(rawValue: 227)],
                mappingIntent: .raw
            )
        )
        XCTAssertEqual(
            ParsecWindowsShortcutCatalog.descriptor(for: .lockWorkstation).chord,
            [RemoteKeyCode(rawValue: 227), RemoteKeyCode(rawValue: 15)]
        )
        XCTAssertEqual(
            ParsecWindowsShortcutCatalog.descriptor(for: .taskManager).chord,
            [
                RemoteKeyCode(rawValue: 224),
                RemoteKeyCode(rawValue: 225),
                RemoteKeyCode(rawValue: 41)
            ]
        )
        XCTAssertEqual(
            ParsecWindowsShortcutCatalog.descriptor(for: .layoutSwitch).chord,
            [RemoteKeyCode(rawValue: 226), RemoteKeyCode(rawValue: 225)]
        )
        XCTAssertEqual(
            ParsecWindowsShortcutCatalog.coverageCount,
            ParsecWindowsShortcutAction.allCases.count
        )
    }

    func testWindowsSecureAttentionIsUnavailableNotFaked() {
        let descriptor = ParsecWindowsShortcutCatalog.descriptor(
            for: .secureAttention
        )
        XCTAssertEqual(descriptor.route, .unavailable)
        XCTAssertTrue(descriptor.chord.isEmpty)
        XCTAssertEqual(descriptor.mappingIntent, .raw)
    }

    func testMacShortcutCatalogClassifiesNativeMacroAndUnavailableRoutes() {
        XCTAssertEqual(
            ParsecMacShortcutCatalog.descriptor(for: .copy),
            ParsecMacShortcutDescriptor(
                action: .copy,
                route: .priorityCapture,
                chord: [
                    RemoteKeyCode(rawValue: 227),
                    RemoteKeyCode(rawValue: 6)
                ]
            )
        )
        XCTAssertEqual(
            ParsecMacShortcutCatalog.descriptor(for: .appSwitcher),
            ParsecMacShortcutDescriptor(
                action: .appSwitcher,
                route: .explicitMacro,
                chord: [
                    RemoteKeyCode(rawValue: 227),
                    RemoteKeyCode(rawValue: 43)
                ]
            )
        )
        XCTAssertEqual(
            ParsecMacShortcutCatalog.descriptor(for: .navigation).route,
            .rawHardware
        )
        XCTAssertEqual(
            ParsecMacShortcutCatalog.descriptor(for: .globeKey).route,
            .unavailable
        )
        XCTAssertTrue(
            ParsecMacShortcutCatalog.descriptor(for: .globeKey).chord.isEmpty
        )
    }

    func testMacShortcutCatalogNeverClaimsReservedActionsAreCaptured() {
        let reserved: [ParsecMacShortcutAction] = [
            .appSwitcher,
            .spotlightOrInputSource,
            .hideApplication,
            .globeKey,
            .ipadHomeGesture
        ]

        for action in reserved {
            XCTAssertNotEqual(
                ParsecMacShortcutCatalog.descriptor(for: action).route,
                .priorityCapture
            )
        }
        XCTAssertEqual(
            ParsecMacShortcutCatalog.coverageCount,
            ParsecMacShortcutAction.allCases.count
        )
    }

    func testMacShortcutMacroChordsUseModifierThenKeyOrder() {
        XCTAssertEqual(
            ParsecMacShortcutCatalog.descriptor(for: .spotlightOrInputSource).chord,
            [RemoteKeyCode(rawValue: 227), RemoteKeyCode(rawValue: 44)]
        )
        XCTAssertEqual(
            ParsecMacShortcutCatalog.descriptor(for: .forceQuit).chord,
            [
                RemoteKeyCode(rawValue: 227),
                RemoteKeyCode(rawValue: 226),
                RemoteKeyCode(rawValue: 41)
            ]
        )
    }

    func testCParsecWindowsMacrosBypassConfiguredCommandRemap() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousMode = SettingsHandler.windowsKeyboardMode
        CParsec.releaseAllKeyboardKeys(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        SettingsHandler.windowsKeyboardMode = .commandAsControl
        defer {
            CParsec.releaseAllKeyboardKeys(reason: .sessionDisconnected)
            SettingsHandler.windowsKeyboardMode = previousMode
            CParsec.parsecImpl = previousService
        }

        XCTAssertTrue(CParsec.sendWindowsShortcut(.startMenu))
        XCTAssertEqual(service.keyboardEvents, ["227:true", "227:false"])
        XCTAssertEqual(service.keyboardMappingIntents, [.raw, .raw])
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 0)

        CParsec.sendKeyboardMessage(
            event: KeyBoardKeyEvent(
                key: RemoteKeyCode(rawValue: 227),
                isPressBegin: true
            )
        )
        XCTAssertTrue(CParsec.sendWindowsShortcut(.lockWorkstation))
        XCTAssertEqual(
            Array(service.keyboardEvents.suffix(5)),
            ["227:true", "227:true", "15:true", "15:false", "227:false"]
        )
        XCTAssertEqual(
            Array(service.keyboardMappingIntents.suffix(5)),
            [.configured, .raw, .raw, .raw, .raw]
        )
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 1)
        CParsec.releaseAllKeyboardKeys(reason: .normal)
        XCTAssertEqual(service.keyboardEvents.last, "227:false")
        XCTAssertEqual(service.keyboardMappingIntents.last, .configured)

        XCTAssertFalse(CParsec.sendWindowsShortcut(.secureAttention))
    }

    func testCParsecGamepadForwardsBalancedButtonsAndIgnoresUnsupported() {
        let previousService: ParsecService? = CParsec.parsecImpl
        CParsec.releaseAllGamepadInputs(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        defer {
            CParsec.releaseAllGamepadInputs(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
        }

        CParsec.sendGameControllerButtonMessage(controllerId: 1, .a, pressed: true)
        CParsec.sendGameControllerButtonMessage(controllerId: 1, .a, pressed: true) // duplicate
        CParsec.sendGameControllerButtonMessage(controllerId: 1, .guide, pressed: true) // unsupported
        CParsec.sendGameControllerButtonMessage(controllerId: 1, .a, pressed: false)
        CParsec.sendGameControllerButtonMessage(controllerId: 1, .a, pressed: false) // orphan

        XCTAssertEqual(service.gamepadButtonEvents, ["1:0:true", "1:0:false"])
        XCTAssertEqual(CParsec.gamepadInputSnapshot.pressedCount, 0)
        XCTAssertEqual(CParsec.gamepadInputSnapshot.unsupportedCount, 1)
    }

    func testCParsecGamepadReleaseAllZeroesHeldButtonsAndAxes() {
        let previousService: ParsecService? = CParsec.parsecImpl
        CParsec.releaseAllGamepadInputs(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        defer {
            CParsec.releaseAllGamepadInputs(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
        }

        CParsec.sendGameControllerButtonMessage(controllerId: 1, .x, pressed: true)
        CParsec.sendGameControllerAxisMessage(controllerId: 1, .leftX, 900)
        XCTAssertEqual(CParsec.gamepadInputSnapshot.pressedCount, 1)
        XCTAssertEqual(CParsec.gamepadInputSnapshot.nonNeutralAxisCount, 1)

        CParsec.releaseAllGamepadInputs(reason: .background)
        XCTAssertEqual(service.gamepadButtonEvents.last, "1:2:false")
        XCTAssertEqual(service.gamepadAxisEvents.last, "1:0:0")
        XCTAssertEqual(CParsec.gamepadInputSnapshot.pressedCount, 0)
        XCTAssertEqual(CParsec.gamepadInputSnapshot.nonNeutralAxisCount, 0)
        XCTAssertEqual(CParsec.gamepadInputSnapshot.lastReleaseReason, .background)
    }

    func testCParsecGamepadUnplugReleasesHeldStateThenUnplugs() {
        let previousService: ParsecService? = CParsec.parsecImpl
        CParsec.releaseAllGamepadInputs(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        defer {
            CParsec.releaseAllGamepadInputs(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
        }

        CParsec.sendGameControllerButtonMessage(controllerId: 1, .b, pressed: true)
        CParsec.sendGameControllerAxisMessage(controllerId: 1, .rightTrigger, 500)
        CParsec.sendGameControllerUnplugMessage(controllerId: 1)

        XCTAssertEqual(service.gamepadButtonEvents, ["1:1:true", "1:1:false"])
        XCTAssertEqual(service.gamepadAxisEvents, ["1:5:500", "1:5:0"])
        XCTAssertEqual(service.gamepadUnplugCount, 1)
        XCTAssertEqual(CParsec.gamepadInputSnapshot.pressedCount, 0)
        XCTAssertEqual(CParsec.gamepadInputSnapshot.nonNeutralAxisCount, 0)
    }

    func testCParsecMacShortcutExecutorOrdersAndReleasesChord() {
        let previousService: ParsecService? = CParsec.parsecImpl
        CParsec.releaseAllKeyboardKeys(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        let previousCompleted = CParsec.shortcutExecutionSnapshot.completedCount
        defer {
            CParsec.releaseAllKeyboardKeys(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
        }

        XCTAssertTrue(CParsec.sendMacShortcut(.appSwitcher))
        XCTAssertEqual(
            service.keyboardEvents,
            ["227:true", "43:true", "43:false", "227:false"]
        )
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 0)
        XCTAssertEqual(
            CParsec.shortcutExecutionSnapshot,
            ParsecShortcutExecutionSnapshot(
                completedCount: previousCompleted + 1,
                lastRoute: .explicitMacro
            )
        )

        CParsec.sendKeyboardMessage(
            event: KeyBoardKeyEvent(
                key: RemoteKeyCode(rawValue: 227),
                isPressBegin: true
            )
        )
        XCTAssertTrue(CParsec.sendMacShortcut(.closeWindow))
        XCTAssertEqual(
            Array(service.keyboardEvents.suffix(3)),
            ["227:true", "26:true", "26:false"]
        )
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 1)
        CParsec.releaseAllKeyboardKeys(reason: .normal)
        XCTAssertEqual(service.keyboardEvents.last, "227:false")

        CParsec.sendKeyboardMessage(
            event: KeyBoardKeyEvent(
                key: RemoteKeyCode(rawValue: 26),
                isPressBegin: true
            )
        )
        XCTAssertTrue(CParsec.sendMacShortcut(.closeWindow))
        XCTAssertEqual(
            Array(service.keyboardEvents.suffix(4)),
            ["26:true", "227:true", "26:true", "227:false"]
        )
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 1)
        CParsec.releaseAllKeyboardKeys(reason: .normal)
        XCTAssertEqual(service.keyboardEvents.last, "26:false")

        XCTAssertTrue(
            CParsec.sendMacShortcut(.closeWindow, route: .explicitMacro)
        )
        XCTAssertEqual(
            CParsec.shortcutExecutionSnapshot.lastRoute,
            .explicitMacro
        )

        let countBeforeUnavailable = service.keyboardEvents.count
        XCTAssertFalse(CParsec.sendMacShortcut(.globeKey))
        XCTAssertEqual(service.keyboardEvents.count, countBeforeUnavailable)
    }

    func testCParsecKeyboardBoundaryForwardsRepeatsAndReleasesHeldKeys() {
        let previousService: ParsecService? = CParsec.parsecImpl
        CParsec.releaseAllKeyboardKeys(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        defer {
            CParsec.releaseAllKeyboardKeys(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
        }
        let letterA = KeyBoardKeyEvent(
            key: RemoteKeyCode(rawValue: 4),
            isPressBegin: true
        )

        CParsec.sendKeyboardMessage(event: letterA)
        CParsec.sendKeyboardMessage(event: letterA)
        CParsec.sendKeyboardMessage(event: letterA)
        CParsec.sendKeyboardMessage(
            event: KeyBoardKeyEvent(key: letterA.key, isPressBegin: false)
        )
        CParsec.sendKeyboardMessage(
            event: KeyBoardKeyEvent(key: letterA.key, isPressBegin: false)
        )
        XCTAssertEqual(
            service.keyboardEvents,
            ["4:true", "4:true", "4:true", "4:false"]
        )
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 0)

        CParsec.sendKeyboardMessage(
            event: KeyBoardKeyEvent(
                key: RemoteKeyCode(rawValue: 224),
                isPressBegin: true
            )
        )
        CParsec.sendKeyboardMessage(
            event: KeyBoardKeyEvent(
                key: RemoteKeyCode(rawValue: 58),
                isPressBegin: true
            )
        )
        CParsec.releaseAllKeyboardKeys(reason: .focusLost)
        XCTAssertEqual(
            Array(service.keyboardEvents.suffix(4)),
            ["224:true", "58:true", "58:false", "224:false"]
        )
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 0)
        XCTAssertEqual(
            CParsec.keyboardInputSnapshot.lastReleaseReason,
            .focusLost
        )
    }

    func testVirtualKeyboardModifiersJoinStateAndTextIsBoundedPerCharacter() {
        let previousService: ParsecService? = CParsec.parsecImpl
        CParsec.releaseAllKeyboardKeys(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        defer {
            CParsec.releaseAllKeyboardKeys(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
        }

        CParsec.sendVirtualKeyboardInput(text: "LGUI", isOn: true)
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 1)
        CParsec.sendVirtualKeyboardInput(text: "LGUI", isOn: false)
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 0)
        XCTAssertEqual(service.keyboardEvents, ["227:true", "227:false"])

        CParsec.sendVirtualKeyboardInput(text: "ab")
        CParsec.sendVirtualKeyboardInput(text: "BACKSPACE")
        XCTAssertEqual(service.virtualTextEvents, ["a", "b", "BACKSPACE"])

        CParsec.sendVirtualKeyboardInput(text: "UNKNOWN-TOKEN", isOn: true)
        XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 0)
    }

    func testCParsecMouseButtonBoundaryRejectsDuplicatesAndReleasesOnCancellation() {
        let previousService: ParsecService? = CParsec.parsecImpl
        CParsec.releaseAllMouseButtons(reason: .reconnect)
        let service = RecordingParsecService(connectResult: .ok)
        CParsec.parsecImpl = service
        defer {
            CParsec.releaseAllMouseButtons(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
        }

        CParsec.sendMouseClickMessage(.left, true)
        CParsec.sendMouseClickMessage(.left, true)
        CParsec.sendMouseClickMessage(.left, false)
        CParsec.sendMouseClickMessage(.left, false)
        XCTAssertEqual(service.mouseButtonEvents, ["click:1:true", "click:1:false"])

        CParsec.sendMouseClickMessage(.right, true)
        CParsec.sendMouseMessage(.middle, 10, 20, true)
        CParsec.releaseAllMouseButtons(reason: .gestureCancelled)
        XCTAssertEqual(
            Array(service.mouseButtonEvents.suffix(4)),
            [
                "click:3:true",
                "positioned:2:true",
                "click:2:false",
                "click:3:false"
            ]
        )
        XCTAssertEqual(
            CParsec.mouseInputSnapshot,
            ParsecMouseInputSnapshot(
                pressedCount: 0,
                lastReleaseReason: .gestureCancelled
            )
        )
    }

    func testRefreshTrackerRejectsStaleResponsesAndWaitsForCurrentBatch() {
        var tracker = ParsecRefreshTracker()
        let first = tracker.begin(requestCount: 3)
        let replacement = tracker.begin(requestCount: 2)

        XCTAssertFalse(tracker.accepts(generation: first))
        XCTAssertFalse(tracker.finish(generation: first))
        XCTAssertEqual(tracker.pendingRequests, 2)
        XCTAssertTrue(tracker.isRefreshing)

        XCTAssertTrue(tracker.finish(generation: replacement))
        XCTAssertTrue(tracker.isRefreshing)
        XCTAssertTrue(tracker.finish(generation: replacement))
        XCTAssertFalse(tracker.isRefreshing)
        XCTAssertFalse(tracker.finish(generation: replacement))
    }

    func testAPIClassifierAcceptsOnlyDecodableSuccess() {
        XCTAssertNil(
            ParsecAPIResponseClassifier.classify(
                endpoint: .hosts,
                statusCode: 200,
                transportFailed: false,
                decodedSuccessfully: true
            )
        )

        let malformed = ParsecAPIResponseClassifier.classify(
            endpoint: .hosts,
            statusCode: 200,
            transportFailed: false,
            decodedSuccessfully: false
        )
        XCTAssertEqual(malformed?.category, .malformedResponse)
        XCTAssertTrue(malformed?.retryable == true)
    }

    func testAPIClassifierSeparatesExpiredSessionFromRejectedLogin() {
        let expired = ParsecAPIResponseClassifier.classify(
            endpoint: .hosts,
            statusCode: 401,
            transportFailed: false,
            decodedSuccessfully: false
        )
        XCTAssertEqual(expired?.category, .sessionExpired)
        XCTAssertTrue(expired?.requiresSignIn == true)

        let rejectedLogin = ParsecAPIResponseClassifier.classify(
            endpoint: .authentication,
            statusCode: 403,
            transportFailed: false,
            decodedSuccessfully: false
        )
        XCTAssertEqual(rejectedLogin?.category, .rejected)
        XCTAssertFalse(rejectedLogin?.requiresSignIn == true)
    }

    func testAPIClassifierCoversMissingOfflineRateLimitAndServer() {
        let missing = ParsecAPIResponseClassifier.classify(
            endpoint: .hosts,
            statusCode: 404,
            transportFailed: false,
            decodedSuccessfully: false
        )
        XCTAssertEqual(missing?.category, .missingResource)
        XCTAssertFalse(missing?.retryable == true)

        let offline = ParsecAPIResponseClassifier.classify(
            endpoint: .hosts,
            statusCode: nil,
            transportFailed: true,
            decodedSuccessfully: false
        )
        XCTAssertEqual(offline?.category, .offline)
        XCTAssertTrue(offline?.retryable == true)

        let limited = ParsecAPIResponseClassifier.classify(
            endpoint: .hosts,
            statusCode: 429,
            transportFailed: false,
            decodedSuccessfully: false
        )
        XCTAssertEqual(limited?.category, .rateLimited)
        XCTAssertTrue(limited?.retryable == true)

        let server = ParsecAPIResponseClassifier.classify(
            endpoint: .friends,
            statusCode: 503,
            transportFailed: false,
            decodedSuccessfully: false
        )
        XCTAssertEqual(server?.category, .server)
        XCTAssertTrue(server?.retryable == true)
    }

    func testAPIFailureDigestIsContentFree() {
        let failure = ParsecAPIFailure(
            endpoint: .hosts,
            category: .sessionExpired,
            statusCode: 401,
            retryable: false,
            requiresSignIn: true
        )
        XCTAssertEqual(
            failure.digest,
            "endpoint=hosts category=session-expired status=401 retryable=false"
        )
        XCTAssertFalse(failure.digest.contains("Bearer"))
        XCTAssertFalse(failure.digest.contains("peer"))
    }

    // Kicked / host shut down are deliberate: surface at once, never reconnect.
    // Positive non-terminal warnings (NETWORK_WRN_TIMEOUT) are not failures.
    func testReconnectRetryWindowCoversVPNReestablishButInitialStaysQuick() {
        let reconnect = (0...).prefix { ParsecConnectRunner.retryDelay(index: $0, intent: .reconnect) != nil }
            .compactMap { ParsecConnectRunner.retryDelay(index: $0, intent: .reconnect) }
        XCTAssertGreaterThanOrEqual(reconnect.reduce(0, +), 30)
        XCTAssertEqual(ParsecConnectRunner.retryDelay(index: 0, intent: .initial), 0.5)
        XCTAssertNil(ParsecConnectRunner.retryDelay(index: 5, intent: .initial))
        XCTAssertNil(ParsecConnectRunner.retryDelay(index: 7, intent: .reconnect))
    }

    func testTransportRecoveryTreatsHostEndedAsTerminalAndWarningsAsProgress() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 2)
        XCTAssertNil(monitor.observe(status: RemoteStatus(rawValue: 2000), generation: 1, isReplacementGeneration: false))
        XCTAssertNil(monitor.observe(status: RemoteStatus(rawValue: 2000), generation: 1, isReplacementGeneration: false))
        XCTAssertEqual(monitor.snapshot.consecutiveFailures, 0)

        let kicked = RemoteStatus(rawValue: 5)
        XCTAssertEqual(
            monitor.observe(status: kicked, generation: 1, isReplacementGeneration: false),
            .terminal(generation: 1, status: kicked)
        )
        XCTAssertFalse(ParsecConnectRunner.isTransient(kicked))
        XCTAssertTrue(ParsecConnectRunner.isTransient(RemoteStatus(rawValue: -6013)))
        XCTAssertFalse(ParsecConnectRunner.isTransient(RemoteStatus(rawValue: -3008)))
    }

    func testTransportRecoveryIsolatedFailureResetsAfterSuccess() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 3)

        XCTAssertNil(
            monitor.observe(
                status: RemoteStatus(rawValue: -6023),
                generation: 1,
                isReplacementGeneration: false
            )
        )
        XCTAssertEqual(monitor.snapshot.consecutiveFailures, 1)

        XCTAssertNil(
            monitor.observe(
                status: .ok,
                generation: 1,
                isReplacementGeneration: false
            )
        )
        XCTAssertEqual(monitor.snapshot.phase, .monitoring)
        XCTAssertEqual(monitor.snapshot.consecutiveFailures, 0)
        XCTAssertFalse(monitor.snapshot.reconnectBudgetUsed)
    }

    func testTransportRecoveryIgnoresFailuresWhileApplicationIsInactive() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 2)

        for _ in 0..<5 {
            XCTAssertNil(
                monitor.observe(
                    status: .notRunning,
                    generation: 1,
                    isReplacementGeneration: false,
                    isObservationAllowed: false
                )
            )
        }

        XCTAssertEqual(monitor.snapshot.phase, .monitoring)
        XCTAssertEqual(monitor.snapshot.consecutiveFailures, 0)

        XCTAssertNil(
            monitor.observe(
                status: .notRunning,
                generation: 1,
                isReplacementGeneration: false,
                isObservationAllowed: true
            )
        )
        XCTAssertEqual(monitor.snapshot.consecutiveFailures, 1)
        XCTAssertEqual(
            monitor.observe(
                status: .notRunning,
                generation: 1,
                isReplacementGeneration: false,
                isObservationAllowed: true
            ),
            .reconnect(generation: 1)
        )
    }

    func testTransportObservationPolicyAllowsOnlyActiveApplication() {
        XCTAssertTrue(
            ParsecTransportObservationPolicy.isAllowed(
                applicationState: .active
            )
        )
        XCTAssertFalse(
            ParsecTransportObservationPolicy.isAllowed(
                applicationState: .inactive
            )
        )
        XCTAssertFalse(
            ParsecTransportObservationPolicy.isAllowed(
                applicationState: .background
            )
        )
    }

    func testOnlyBackgroundReconnectKeepsSessionPresentationVisible() {
        XCTAssertFalse(
            ParsecRecoveryPresentationPolicy.shouldDismissSession(
                pictureInPictureActive: false,
                automaticReconnectPending: true,
                preservesBackgroundPresentation: true
            )
        )
        XCTAssertTrue(
            ParsecRecoveryPresentationPolicy.shouldDismissSession(
                pictureInPictureActive: false,
                automaticReconnectPending: true,
                preservesBackgroundPresentation: false
            )
        )
        XCTAssertFalse(
            ParsecRecoveryPresentationPolicy.shouldDismissSession(
                pictureInPictureActive: true,
                automaticReconnectPending: false,
                preservesBackgroundPresentation: false
            )
        )
        XCTAssertTrue(
            ParsecRecoveryPresentationPolicy.shouldDismissSession(
                pictureInPictureActive: false,
                automaticReconnectPending: false,
                preservesBackgroundPresentation: true
            )
        )
    }

    func testTouchInteractionPolicyInterruptsMomentumOnlyWhenPanBegins() {
        XCTAssertTrue(
            ParsecTouchInteractionPolicy.shouldInterruptScrollMomentum(
                for: .began
            )
        )
        XCTAssertFalse(
            ParsecTouchInteractionPolicy.shouldInterruptScrollMomentum(
                for: .changed
            )
        )
        XCTAssertFalse(
            ParsecTouchInteractionPolicy.shouldInterruptScrollMomentum(
                for: .ended
            )
        )
    }

    func testTrackpadScrollMomentumStopsBeforeEveryLiveDelta() {
        XCTAssertTrue(
            ParsecTouchInteractionPolicy.shouldInterruptTrackpadMomentum(
                for: .began
            )
        )
        XCTAssertTrue(
            ParsecTouchInteractionPolicy.shouldInterruptTrackpadMomentum(
                for: .changed
            )
        )
        XCTAssertFalse(
            ParsecTouchInteractionPolicy.shouldInterruptTrackpadMomentum(
                for: .ended
            )
        )
    }

    func testScrollGlideStopsAtConfiguredDuration() {
        XCTAssertTrue(
            ParsecScrollMomentumPolicy.shouldContinue(
                elapsed: 0.59,
                maximumDuration: 0.6
            )
        )
        XCTAssertFalse(
            ParsecScrollMomentumPolicy.shouldContinue(
                elapsed: 0.6,
                maximumDuration: 0.6
            )
        )
        XCTAssertFalse(
            ParsecScrollMomentumPolicy.shouldContinue(
                elapsed: 0,
                maximumDuration: 0
            )
        )
    }

    func testScrollGlideDurationClampsPersistedOutliers() {
        XCTAssertEqual(ParsecScrollMomentumPolicy.clampedDuration(-1), 0)
        XCTAssertEqual(ParsecScrollMomentumPolicy.clampedDuration(0.6), 0.6)
        XCTAssertEqual(ParsecScrollMomentumPolicy.clampedDuration(9), 1.2)
    }

    func testScrollMomentumKeepsOneObservedPeakVector() {
        let horizontal = ParsecInputDelta(x: 500, y: 20)
        let verticalButSlower = ParsecInputDelta(x: 10, y: 400)
        XCTAssertEqual(
            ParsecScrollMomentumPolicy.peakVelocity(
                current: horizontal,
                candidate: verticalButSlower
            ),
            horizontal
        )

        let fasterDiagonal = ParsecInputDelta(x: 450, y: 450)
        XCTAssertEqual(
            ParsecScrollMomentumPolicy.peakVelocity(
                current: horizontal,
                candidate: fasterDiagonal
            ),
            fasterDiagonal
        )
    }

    func testGlideSeedCapsFlickSpeedButKeepsDirection() {
        let seed = ParsecScrollMomentumPolicy.glideSeed(ParsecInputDelta(x: 0, y: -12000))
        XCTAssertEqual(seed.y, -ParsecScrollMomentumPolicy.maximumStartSpeed, accuracy: 0.001)
        XCTAssertEqual(seed.x, 0)
        let slow = ParsecInputDelta(x: 30, y: 400)
        XCTAssertEqual(ParsecScrollMomentumPolicy.glideSeed(slow), slow)
    }

    // Users still on the old ⌃Space default move to ⌘Space once (macOS
    // input-source switch; Win+Space on Windows); explicit choices stick.
    // Device log 11:36: -14 after a background return was "tolerated" because
    // the pre-render callback (which fires on re-draws too) looked like live
    // frames; the picture froze forever. A decode error is never healthy.
    func testDecodeErrorRangeIsExactlyDecoderStatuses() {
        for raw: Int32 in -23 ... -10 {
            XCTAssertTrue(ParsecDecodeErrorPolicy.isDecodeError(RemoteStatus(rawValue: raw)))
        }
        for raw: Int32 in [-24, -9, -6, -3, 0, 20, 1003, -6023, -12007] {
            XCTAssertFalse(ParsecDecodeErrorPolicy.isDecodeError(RemoteStatus(rawValue: raw)))
        }
    }

    func testDecodeErrorReconnectsOnFirstPollWithoutStreak() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 5)
        XCTAssertEqual(
            monitor.observe(
                status: RemoteStatus(rawValue: -14),
                generation: 2,
                isReplacementGeneration: false
            ),
            .reconnect(generation: 2)
        )
        XCTAssertEqual(monitor.snapshot.phase, .reconnectRequested)
        // Transport failures still need the full streak.
        var transport = ParsecTransportRecoveryMonitor(failureThreshold: 5)
        XCTAssertNil(
            transport.observe(
                status: RemoteStatus(rawValue: -6023),
                generation: 2,
                isReplacementGeneration: false
            )
        )
    }

    // Each suspend/resume flip must change the config decode_thread compares
    // (that is what drops the VT decoder) and end on the user's value.
    func testVideoSuspendFlipsDecoderCompatibilityAndRestoresIt() {
        for user in [false, true] {
            let suspended = ParsecVideoSuspendPolicy.decoderCompatibility(user: user, suspended: true)
            let resumed = ParsecVideoSuspendPolicy.decoderCompatibility(user: user, suspended: false)
            XCTAssertNotEqual(suspended, user)
            XCTAssertEqual(resumed, user)
        }
    }

    func testVideoResumeRecoveryWaitsNudgesThenFallsBackToReconnect() {
        typealias P = ParsecVideoSuspendPolicy
        let ok = RemoteStatus.ok
        XCTAssertEqual(P.recovery(elapsed: 0.2, decoded: false, status: ok, nudged: false), .waiting)
        XCTAssertEqual(P.recovery(elapsed: 0.2, decoded: true, status: ok, nudged: false), .recovered)
        XCTAssertEqual(P.recovery(elapsed: P.nudgeAfter, decoded: false, status: ok, nudged: false), .nudge)
        XCTAssertEqual(P.recovery(elapsed: P.nudgeAfter, decoded: false, status: ok, nudged: true), .waiting)
        XCTAssertEqual(P.recovery(elapsed: P.stallAfter, decoded: false, status: ok, nudged: true), .stalled)
        // A late frame still counts as recovery, never as a stall.
        XCTAssertEqual(P.recovery(elapsed: 10, decoded: true, status: ok, nudged: true), .recovered)
        // A real decode error is already fatal (decode_thread exited).
        XCTAssertEqual(
            P.recovery(elapsed: 0.1, decoded: true, status: RemoteStatus(rawValue: -14), nudged: false),
            .failed
        )
        // The stall is reported as a decode error, so the existing monitor
        // performs the one last-resort reconnect.
        XCTAssertTrue(ParsecDecodeErrorPolicy.isDecodeError(RemoteStatus(rawValue: -14)))
    }

    func testDecodeErrorOnUnfinishedReplacementIsTerminal() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 5)
        XCTAssertEqual(
            monitor.observe(
                status: RemoteStatus(rawValue: -14),
                generation: 3,
                isReplacementGeneration: true
            ),
            .terminal(generation: 3, status: RemoteStatus(rawValue: -14))
        )
    }

    func testDisplayToggleTargetsTheOtherOfTwoMonitors() {
        func config(_ id: String) -> ParsecDisplayConfig {
            ParsecDisplayConfig(name: "DELL", adapterName: "GPU", id: id)
        }
        let two = [config("1"), config("3")]
        XCTAssertEqual(ParsecDisplayConfig.toggleTarget(in: two, current: "1")?.id, "3")
        XCTAssertEqual(ParsecDisplayConfig.toggleTarget(in: two, current: "3")?.id, "1")
        XCTAssertEqual(ParsecDisplayConfig.toggleTarget(in: two, current: "none")?.id, "1")
        XCTAssertNil(ParsecDisplayConfig.toggleTarget(in: [config("1")], current: "1"))
        XCTAssertNil(ParsecDisplayConfig.toggleTarget(in: two + [config("5")], current: "1"))
    }

    func testLayoutSyncHotkeyMigratesOldDefaultOnce() {
        let suite = "layout-sync-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ParsecSettingID.layoutSyncHotkey.rawValue

        defaults.set(LayoutSyncHotkey.ctrlSpace.rawValue, forKey: key)
        SettingsHandler.migrateLayoutSyncHotkeyIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: key), LayoutSyncHotkey.cmdSpace.rawValue)

        defaults.set(LayoutSyncHotkey.ctrlSpace.rawValue, forKey: key)
        SettingsHandler.migrateLayoutSyncHotkeyIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: key), LayoutSyncHotkey.ctrlSpace.rawValue)

        XCTAssertEqual(SettingsDefaults.layoutSyncHotkey, .cmdSpace)
    }

    func testScrollMomentumAdoptsLatestVelocityWhenGestureSlowsToAStop() {
        let flick = ParsecInputDelta(x: 0, y: 900)
        let stopped = ParsecInputDelta(x: 0, y: 5)
        let peak = ParsecScrollMomentumPolicy.peakVelocity(
            current: flick,
            candidate: stopped
        )
        XCTAssertEqual(peak, stopped)
        XCTAssertFalse(
            ParsecScrollMomentumPolicy.shouldStart(
                travel: 200,
                peakSpeed: hypot(peak.x, peak.y)
            )
        )
    }

    func testVirtualKeyTapReleasesEveryPressAndRespectsHeldShift() {
        for (needsShift, shiftHeld) in [(false, false), (true, false), (true, true), (false, true)] {
            let taps = ParsecVirtualKeyTap.sequence(code: 4, needsShift: needsShift, shiftHeld: shiftHeld)
            var held = Set<UInt32>()
            for tap in taps {
                if tap.pressed {
                    XCTAssertTrue(held.insert(tap.code).inserted)
                } else {
                    XCTAssertNotNil(held.remove(tap.code))
                }
            }
            XCTAssertTrue(held.isEmpty)
            XCTAssertEqual(
                taps.contains { $0.code == ParsecVirtualKeyTap.leftShift },
                needsShift && !shiftHeld
            )
        }
        XCTAssertEqual(
            ParsecVirtualKeyTap.sequence(code: 4, needsShift: true, shiftHeld: false).map { $0.code },
            [225, 4, 4, 225]
        )
    }

    func testCapturedSystemKeyCombosAllIncludeCommand() {
        XCTAssertTrue(
            ParsecViewController._capturableModifierCombos.allSatisfy {
                $0.contains(.command)
            }
        )
    }

    func testScrollMomentumRequiresMeaningfulFlickTravelAndSpeed() {
        XCTAssertFalse(
            ParsecScrollMomentumPolicy.shouldStart(
                travel: 4,
                peakSpeed: 800
            )
        )
        XCTAssertFalse(
            ParsecScrollMomentumPolicy.shouldStart(
                travel: 40,
                peakSpeed: 30
            )
        )
        XCTAssertTrue(
            ParsecScrollMomentumPolicy.shouldStart(
                travel: 40,
                peakSpeed: 300
            )
        )
    }

    func testTouchpadDragConfigurationUsesShortHoldWithDriftTolerance() {
        XCTAssertLessThanOrEqual(
            ParsecTouchInteractionPolicy.dragMinimumPressDuration,
            0.2
        )
        XCTAssertGreaterThanOrEqual(
            ParsecTouchInteractionPolicy.dragAllowableMovement,
            32
        )
    }

    func testIndirectPointerButtonMaskMapsPrimaryAndSecondaryButtons() {
        let none = ParsecPointerButtonMaskSnapshot(buttonMask: [])
        XCTAssertFalse(none.primaryPressed)
        XCTAssertFalse(none.secondaryPressed)

        let primary = ParsecPointerButtonMaskSnapshot(buttonMask: [.primary])
        XCTAssertTrue(primary.primaryPressed)
        XCTAssertFalse(primary.secondaryPressed)

        let both = ParsecPointerButtonMaskSnapshot(
            buttonMask: [.primary, .secondary]
        )
        XCTAssertTrue(both.primaryPressed)
        XCTAssertTrue(both.secondaryPressed)
    }

    func testNativePointerMotionTransfersFromHoverToTouchDuringDrag() {
        XCTAssertTrue(
            ParsecPointerMotionOwnership.usesHover(
                route: .absolute,
                pressedButtonCount: 0
            )
        )

        XCTAssertFalse(
            ParsecPointerMotionOwnership.usesHover(
                route: .absolute,
                pressedButtonCount: 1
            )
        )
        XCTAssertTrue(
            ParsecPointerMotionOwnership.usesNativeDragPan(
                route: .absolute,
                pressedButtonCount: 1
            )
        )
        XCTAssertFalse(
            ParsecPointerMotionOwnership.usesNativeDragPan(
                route: .absolute,
                pressedButtonCount: 0
            )
        )

        XCTAssertFalse(
            ParsecPointerMotionOwnership.usesHover(
                route: .relative,
                pressedButtonCount: 1
            )
        )
        XCTAssertFalse(
            ParsecPointerMotionOwnership.usesNativeDragPan(
                route: .relative,
                pressedButtonCount: 1
            )
        )
    }

    func testPiPCapturePolicyPrerollsOnceThenCapturesOnlyForTransitionOrActivePiP() {
        XCTAssertTrue(
            ParsecPiPCapturePolicy.shouldCapture(
                isActive: false,
                isStarting: false,
                hasPreparedSample: false
            )
        )
        XCTAssertFalse(
            ParsecPiPCapturePolicy.shouldCapture(
                isActive: false,
                isStarting: false,
                hasPreparedSample: true
            )
        )
        XCTAssertTrue(
            ParsecPiPCapturePolicy.shouldCapture(
                isActive: false,
                isStarting: true,
                hasPreparedSample: true
            )
        )
        XCTAssertTrue(
            ParsecPiPCapturePolicy.shouldCapture(
                isActive: true,
                isStarting: false,
                hasPreparedSample: true
            )
        )
    }

    func testPiPStartPolicyRequiresOneReadyAttachedSurface() {
        XCTAssertTrue(
            ParsecPiPStartPolicy.isReady(
                isSetup: true,
                isActive: false,
                isStarting: false,
                hasController: true,
                hasAttachedSource: true,
                hasSampleBuffer: true,
                layerFailed: false
            )
        )

        XCTAssertFalse(
            ParsecPiPStartPolicy.isReady(
                isSetup: true,
                isActive: false,
                isStarting: false,
                hasController: true,
                hasAttachedSource: true,
                hasSampleBuffer: false,
                layerFailed: false
            )
        )
        XCTAssertFalse(
            ParsecPiPStartPolicy.isReady(
                isSetup: true,
                isActive: false,
                isStarting: false,
                hasController: true,
                hasAttachedSource: false,
                hasSampleBuffer: true,
                layerFailed: false
            )
        )
        XCTAssertFalse(
            ParsecPiPStartPolicy.isReady(
                isSetup: true,
                isActive: false,
                isStarting: false,
                hasController: true,
                hasAttachedSource: true,
                hasSampleBuffer: true,
                layerFailed: true
            )
        )
    }

    func testPiPDidStartStopsLateTransitionAfterForegroundCancellation() {
        XCTAssertFalse(
            ParsecPiPTransitionPolicy.shouldLatchCancellation(
                isStarting: true,
                startSubmittedToAVKit: false
            )
        )
        XCTAssertTrue(
            ParsecPiPTransitionPolicy.shouldLatchCancellation(
                isStarting: true,
                startSubmittedToAVKit: true
            )
        )

        XCTAssertEqual(
            ParsecPiPTransitionPolicy.didStartAction(
                isExpectedController: true,
                isStarting: false,
                cancelRequestedWhileStarting: true
            ),
            .stopWithoutProtection
        )
        XCTAssertEqual(
            ParsecPiPTransitionPolicy.didStartAction(
                isExpectedController: true,
                isStarting: true,
                cancelRequestedWhileStarting: false
            ),
            .activateProtection
        )
        XCTAssertEqual(
            ParsecPiPTransitionPolicy.didStartAction(
                isExpectedController: false,
                isStarting: true,
                cancelRequestedWhileStarting: false
            ),
            .ignore
        )
    }

    func testReplacementConnectingStatusNeverConsumesReconnectBudget() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 2)

        for _ in 0..<10 {
            XCTAssertNil(
                monitor.observe(
                    status: .connecting,
                    generation: 2,
                    isReplacementGeneration: true
                )
            )
        }

        XCTAssertEqual(monitor.snapshot.consecutiveFailures, 0)
        XCTAssertEqual(monitor.snapshot.phase, .monitoring)
        XCTAssertTrue(monitor.snapshot.reconnectBudgetUsed)
        XCTAssertEqual(monitor.snapshot.lastStatus, .connecting)
    }

    func testTransportRecoveryRequestsExactlyOneReconnectAtThreshold() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 2)
        let failed = RemoteStatus(rawValue: -6023)

        XCTAssertNil(
            monitor.observe(
                status: failed,
                generation: 4,
                isReplacementGeneration: false
            )
        )
        XCTAssertEqual(
            monitor.observe(
                status: failed,
                generation: 4,
                isReplacementGeneration: false
            ),
            .reconnect(generation: 4)
        )
        XCTAssertNil(
            monitor.observe(
                status: failed,
                generation: 4,
                isReplacementGeneration: false
            )
        )
        XCTAssertEqual(monitor.snapshot.phase, .reconnectRequested)
        XCTAssertTrue(monitor.snapshot.reconnectBudgetUsed)
    }

    func testTransportRecoveryReplacementBudgetPersistsUntilInteractive() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 2)

        XCTAssertNil(
            monitor.observe(
                status: .ok,
                generation: 9,
                isReplacementGeneration: true,
                isSessionInteractive: false
            )
        )
        XCTAssertTrue(monitor.snapshot.reconnectBudgetUsed)

        XCTAssertNil(
            monitor.observe(
                status: .ok,
                generation: 9,
                isReplacementGeneration: true,
                isSessionInteractive: true
            )
        )
        XCTAssertFalse(monitor.snapshot.reconnectBudgetUsed)
    }

    func testTransportRecoveryReplacementFailureBecomesTerminal() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 2)
        let failed = RemoteStatus(rawValue: -6023)

        XCTAssertNil(
            monitor.observe(
                status: failed,
                generation: 9,
                isReplacementGeneration: true
            )
        )
        XCTAssertEqual(
            monitor.observe(
                status: failed,
                generation: 9,
                isReplacementGeneration: true
            ),
            .terminal(generation: 9, status: failed)
        )
        XCTAssertEqual(monitor.snapshot.phase, .terminal)
    }

    func testTransportRecoveryIgnoresStaleGeneration() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 1)
        XCTAssertNil(
            monitor.observe(
                status: .ok,
                generation: 7,
                isReplacementGeneration: false
            )
        )

        XCTAssertNil(
            monitor.observe(
                status: RemoteStatus(rawValue: -6023),
                generation: 6,
                isReplacementGeneration: false
            )
        )
        XCTAssertEqual(monitor.snapshot.generation, 7)
        XCTAssertEqual(monitor.snapshot.phase, .monitoring)
    }

    func testTransportRecoveryCancellationSuppressesReconnect() {
        var monitor = ParsecTransportRecoveryMonitor(failureThreshold: 1)
        monitor.cancel(generation: 3)

        XCTAssertNil(
            monitor.observe(
                status: RemoteStatus(rawValue: -6023),
                generation: 3,
                isReplacementGeneration: false
            )
        )
        XCTAssertEqual(monitor.snapshot.phase, .cancelled)
    }

    func testCParsecRepeatedConnectCyclesAdvanceGenerationAndReleaseAllInput() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousPeer = CParsec.lastConnectedPeerID
        CParsec.disconnect()
        CParsec.releaseAllMouseButtons(reason: .sessionDisconnected)
        CParsec.releaseAllKeyboardKeys(reason: .sessionDisconnected)
        CParsec.releaseAllGamepadInputs(reason: .sessionDisconnected)

        let service = RecordingParsecService(connectResult: .connecting)
        CParsec.parsecImpl = service
        let baseline = CParsec.concurrencySnapshot
        defer {
            CParsec.disconnect()
            CParsec.releaseAllMouseButtons(reason: .sessionDisconnected)
            CParsec.releaseAllKeyboardKeys(reason: .sessionDisconnected)
            CParsec.releaseAllGamepadInputs(reason: .sessionDisconnected)
            CParsec.parsecImpl = previousService
            CParsec.lastConnectedPeerID = previousPeer
        }

        var previousGeneration = baseline.generation
        for index in 0..<5 {
            XCTAssertEqual(CParsec.connect("cycle-peer-\(index)"), .connecting)

            let connected = CParsec.concurrencySnapshot
            XCTAssertEqual(connected.generation, previousGeneration + 1)
            XCTAssertEqual(connected.connectCycles, baseline.connectCycles + index + 1)
            XCTAssertTrue(connected.isAtRest)

            CParsec.sendMouseClickMessage(.left, true)
            CParsec.sendKeyboardMessage(
                event: KeyBoardKeyEvent(
                    key: RemoteKeyCode(rawValue: 4),
                    isPressBegin: true
                )
            )
            CParsec.sendGameControllerButtonMessage(controllerId: 1, .a, pressed: true)
            CParsec.sendGameControllerAxisMessage(controllerId: 1, .leftX, 900)

            let active = CParsec.concurrencySnapshot
            XCTAssertEqual(active.outstandingInput, 4)
            XCTAssertFalse(active.isAtRest)

            XCTAssertTrue(CParsec.disconnect())
            let disconnected = CParsec.concurrencySnapshot
            XCTAssertEqual(disconnected.generation, connected.generation)
            XCTAssertTrue(disconnected.isAtRest)
            XCTAssertEqual(CParsec.mouseInputSnapshot.pressedCount, 0)
            XCTAssertEqual(CParsec.keyboardInputSnapshot.pressedCount, 0)
            XCTAssertEqual(CParsec.gamepadInputSnapshot.pressedCount, 0)
            XCTAssertEqual(CParsec.gamepadInputSnapshot.nonNeutralAxisCount, 0)
            previousGeneration = connected.generation
        }
    }

    func testCParsecRejectedDuplicateConnectDoesNotAdvanceConcurrencySnapshot() {
        let previousService: ParsecService? = CParsec.parsecImpl
        let previousPeer = CParsec.lastConnectedPeerID
        CParsec.disconnect()
        let service = RecordingParsecService(connectResult: .connecting)
        CParsec.parsecImpl = service
        defer {
            CParsec.disconnect()
            CParsec.parsecImpl = previousService
            CParsec.lastConnectedPeerID = previousPeer
        }

        XCTAssertEqual(CParsec.connect("duplicate-peer"), .connecting)
        let first = CParsec.concurrencySnapshot
        XCTAssertEqual(CParsec.connect("duplicate-peer"), .connecting)
        let duplicate = CParsec.concurrencySnapshot

        XCTAssertEqual(duplicate.generation, first.generation)
        XCTAssertEqual(duplicate.connectCycles, first.connectCycles)
    }

}

private extension ParsecKeyboardStateMachine {
    var digestContainsInputContent: Bool {
        let value = snapshot.digest.lowercased()
        return value.contains("return")
            || value.contains("arrow")
            || value.contains("control")
            || value.contains("shift")
            || value.contains("key=")
    }
}

private final class RecordingParsecService: ParsecService {
    let adapterKind: ParsecAdapterKind = .fake
    var clientWidth: Float = 1024
    var clientHeight: Float = 768
    var hostWidth: Float = 1920
    var hostHeight: Float = 1080
    var mouseInfo = MouseInfo()
    var hostOSValue = -1
    var mediaReadiness: ParsecMediaReadiness = .notReady
    var mediaEvidence: ParsecMediaEvidence {
        ParsecMediaEvidence(
            readiness: mediaReadiness,
            videoStatus: nil,
            audioStatus: nil
        )
    }

    var statusResult: RemoteStatus
    var renderHook: (() -> Void)?
    private(set) var connectedPeerID: String?
    private(set) var didDisconnect = false
    private(set) var disconnectCount = 0
    private(set) var mouseButtonEvents: [String] = []
    private(set) var keyboardEvents: [String] = []
    private(set) var keyboardMappingIntents: [ParsecKeyboardMappingIntent] = []
    private(set) var virtualTextEvents: [String] = []
    private(set) var gamepadButtonEvents: [String] = []
    private(set) var gamepadAxisEvents: [String] = []
    private(set) var gamepadUnplugCount = 0
    private let disconnectLock = NSLock()

    init(connectResult: RemoteStatus) {
        statusResult = connectResult
    }

    func connect(_ peerID: String) -> RemoteStatus {
        connectedPeerID = peerID
        return statusResult
    }

    func disconnect() {
        disconnectLock.lock()
        defer { disconnectLock.unlock() }
        didDisconnect = true
        disconnectCount += 1
    }

    func getStatus() -> RemoteStatus { statusResult }
    func getStatusEx() -> RemoteClientStatus { RemoteClientStatus(status: statusResult) }
    func setMuted(_ muted: Bool) {}
    func applyConfig() {}
    func sendUserData(type: ParsecUserDataType, message: Data) {}
    func updateHostVideoConfig() {}
    func setFrame(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) {}
    func renderGLFrame(timeout: UInt32) -> ParsecRenderFrameResult {
        renderHook?()
        return .produced()
    }
    func sendMouseMessage(_ button: RemoteMouseButton, _ x: Int32, _ y: Int32, _ pressed: Bool) {
        mouseButtonEvents.append("positioned:\(button.rawValue):\(pressed)")
    }
    func sendMouseClickMessage(_ button: RemoteMouseButton, _ pressed: Bool) {
        mouseButtonEvents.append("click:\(button.rawValue):\(pressed)")
    }
    func sendMouseDelta(_ dx: Int32, _ dy: Int32) {}
    func sendMousePosition(_ x: Int32, _ y: Int32) {}
    func sendKeyboardMessage(event: KeyBoardKeyEvent) {
        keyboardEvents.append("\(event.key.rawValue):\(event.isPressBegin)")
        keyboardMappingIntents.append(event.mappingIntent)
    }
    func sendVirtualKeyboardInput(text: String) {
        virtualTextEvents.append(text)
    }
    func sendGameControllerButtonMessage(controllerId: UInt32, _ button: RemoteGamepadButton, pressed: Bool) {
        gamepadButtonEvents.append("\(controllerId):\(button.rawValue):\(pressed)")
    }
    func sendGameControllerAxisMessage(controllerId: UInt32, _ axis: RemoteGamepadAxis, _ value: Int16) {
        gamepadAxisEvents.append("\(controllerId):\(axis.rawValue):\(value)")
    }
    func sendGameControllerUnplugMessage(controllerId: UInt32) {
        gamepadUnplugCount += 1
    }
    func sendWheelMsg(x: Int32, y: Int32) {}
}

private final class ClientTypesFailureStore: ParsecFailurePersisting {
    func loadLastFailure() -> ParsecSessionFailure? { nil }
    func saveLastFailure(_ failure: ParsecSessionFailure) {}
}

private final class ClientTypesTransitionLogger: ParsecSessionTransitionLogging {
    func log(_ transition: ParsecSessionTransition) {}
}

final class ParsecConnectionTestTests: XCTestCase {
    private let txid: [UInt8] = Array(1...12)
    private let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

    private func response(attrType: UInt16, family: UInt8, port: UInt16, address: [UInt8], txid: [UInt8]? = nil) -> Data {
        let xor = attrType == 0x0020
        let mask = xor ? cookie + self.txid : [UInt8](repeating: 0, count: 16)
        let p = xor ? port ^ 0x2112 : port
        let value: [UInt8] = [0, family, UInt8(p >> 8), UInt8(p & 0xFF)] + address.enumerated().map { $0.element ^ mask[$0.offset] }
        let attr: [UInt8] = [UInt8(attrType >> 8), UInt8(attrType & 0xFF), 0, UInt8(value.count)] + value
        return Data([0x01, 0x01, 0, UInt8(attr.count)] + cookie + (txid ?? self.txid) + attr)
    }

    func testBindingRequestLayout() {
        let request = [UInt8](ParsecConnectionTest.stunBindingRequest(transactionID: txid))
        XCTAssertEqual(request, [0x00, 0x01, 0x00, 0x00] + cookie + txid)
    }

    func testParsesIPv4XorAndPlainMappedAddress() {
        let xor = ParsecConnectionTest.parseStunMappedAddress(response(attrType: 0x0020, family: 1, port: 13170, address: [14, 212, 85, 47]), transactionID: txid)
        XCTAssertEqual(xor?.ip, "14.212.85.47")
        XCTAssertEqual(xor?.port, 13170)
        // RFC 3489 servers (e.g. stun.miwifi.com) only send MAPPED-ADDRESS.
        let plain = ParsecConnectionTest.parseStunMappedAddress(response(attrType: 0x0001, family: 1, port: 40000, address: [216, 36, 118, 55]), transactionID: txid)
        XCTAssertEqual(plain?.ip, "216.36.118.55")
        XCTAssertEqual(plain?.port, 40000)
    }

    func testParsesIPv6XorMappedAddress() {
        let address: [UInt8] = [0x24, 0x0e, 0x03, 0xb7] + [UInt8](repeating: 0, count: 11) + [1]
        let parsed = ParsecConnectionTest.parseStunMappedAddress(response(attrType: 0x0020, family: 2, port: 3478, address: address), transactionID: txid)
        XCTAssertEqual(parsed?.ip, "240e:3b7::1")
        XCTAssertEqual(parsed?.port, 3478)
    }

    func testRejectsWrongTransactionIDAndGarbage() {
        let foreign = response(attrType: 0x0020, family: 1, port: 1, address: [1, 2, 3, 4], txid: Array(repeating: 9, count: 12))
        XCTAssertNil(ParsecConnectionTest.parseStunMappedAddress(foreign, transactionID: txid))
        XCTAssertNil(ParsecConnectionTest.parseStunMappedAddress(Data([1, 1, 0]), transactionID: txid))
    }

    func testVerdictMapping() {
        func v(online: Bool = true, vpn: Bool = false, parsec: Bool = true, mapped: [String] = ["1.2.3.4:5", "1.2.3.4:5"], v6: Bool = true) -> String {
            ParsecConnectionTest.verdict(online: online, vpnPrimary: vpn, parsecReachable: parsec, mapped: mapped, ipv6UDP: v6)
        }
        XCTAssertTrue(v(online: false).hasPrefix("No network"))
        XCTAssertTrue(v(vpn: true, mapped: [], v6: false).contains("VPN is capturing UDP"))
        XCTAssertTrue(v(mapped: [], v6: false).contains("network blocks UDP"))
        XCTAssertTrue(v(parsec: false).hasPrefix("Parsec servers unreachable"))
        XCTAssertTrue(v(vpn: true).hasPrefix("The VPN is the primary route"))
        XCTAssertTrue(v(mapped: ["1.2.3.4:5", "1.2.3.4:6"], v6: false).hasPrefix("Symmetric NAT on IPv4 and no IPv6"))
        XCTAssertTrue(v(mapped: ["1.2.3.4:5", "1.2.3.4:6"]).contains("IPv6 works"))
        XCTAssertTrue(v(v6: false).hasPrefix("No global IPv6"))
        XCTAssertTrue(v().hasPrefix("All good"))
    }

    func testDisplayRestorePrefersIdPlusNameAndRefusesAmbiguousGuesses() {
        let dell1 = ParsecDisplayConfig(name: "DELL U2720Q", adapterName: "NVIDIA RTX", id: "\\\\.\\DISPLAY1")
        let dell2 = ParsecDisplayConfig(name: "DELL U2720Q", adapterName: "NVIDIA RTX", id: "\\\\.\\DISPLAY2")
        let lg = ParsecDisplayConfig(name: "LG UltraFine", adapterName: "NVIDIA RTX", id: "\\\\.\\DISPLAY3")
        let all = [dell1, dell2, lg]
        func match(_ id: String, _ name: String) -> String? {
            ParsecDisplayConfig.restoreMatch(in: all, savedId: id, savedName: name)?.id
        }
        // Identical monitors: the id disambiguates.
        XCTAssertEqual(match(dell2.id, dell2.label), dell2.id)
        // Ids reassigned: the saved id now belongs to another monitor; the unique name wins.
        XCTAssertEqual(match(dell1.id, lg.label), lg.id)
        // Id rolled and name is ambiguous: don't guess.
        XCTAssertNil(match("\\\\.\\DISPLAY9", dell1.label))
        // Legacy save without a name: id only.
        XCTAssertEqual(match(lg.id, ""), lg.id)
        XCTAssertNil(match("missing", ""))
        XCTAssertNil(match("", ""))
    }

    func testDisplayMenuLabelsDisambiguateIdenticalMonitors() {
        let a = ParsecDisplayConfig(name: "DELL", adapterName: "Apple M2", id: "1")
        let b = ParsecDisplayConfig(name: "DELL", adapterName: "Apple M2", id: "2")
        let c = ParsecDisplayConfig(name: "Built-in", adapterName: "Apple M2", id: "3")
        let all = [a, b, c]
        XCTAssertEqual(a.menuLabel(in: all), "DELL Apple M2 (1)")
        XCTAssertEqual(b.menuLabel(in: all), "DELL Apple M2 (2)")
        XCTAssertEqual(c.menuLabel(in: all), "Built-in Apple M2")
        XCTAssertEqual(Set(all.map { $0.menuLabel(in: all) }).count, all.count)
    }

    func testVideoConfigWireCarriesBitrateMbpsFullFpsAndOutput() throws {
        var config = ParsecUserDataVideoConfig()
        config.video[0].encoderMaxBitrate = 30 // Mbps: host log "B:x/30.0"
        config.video[0].fullFPS = true
        config.video[0].output = "2"
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        )
        let video = try XCTUnwrap((json["video"] as? [[String: Any]])?.first)
        XCTAssertEqual(video["encoderMaxBitrate"] as? Int, 30)
        XCTAssertEqual(video["fullFPS"] as? Bool, true)
        XCTAssertEqual(video["output"] as? String, "2")
        // The echo decodes through the same struct.
        let echo = try JSONDecoder().decode(ParsecUserDataVideoConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(echo.video[0].output, "2")
        XCTAssertTrue(echo.video[0].fullFPS)
    }

    // MARK: - Stream geometry (aspect-fit)

    func testAspectFitMatchesDeviceViewportForMacHostOnIPadPro11() {
        // Device log: 3024x1964 stream, 1408x970 pt view at 1.7196 →
        // GL viewport 0,48,2421,1572.
        let scale: CGFloat = 1.7195876288659795
        let fit = ParsecResolution.aspectFit(
            CGSize(width: 3024, height: 1964),
            in: CGSize(width: 1408, height: 970)
        )
        XCTAssertEqual(fit.minX, 0, accuracy: 0.001)
        XCTAssertEqual(fit.width * scale, 2421, accuracy: 1)
        XCTAssertEqual(fit.height * scale, 1572, accuracy: 1)
        XCTAssertEqual(fit.minY * scale, 48, accuracy: 1)
    }

    func testAspectFitLetterboxesEveryResolutionOnEveryScreenWithoutStretchOrCrop() {
        let screens: [CGSize] = [
            CGSize(width: 1408, height: 970),  // iPad Pro 11" M4, More Space
            CGSize(width: 1210, height: 834),  // iPad Pro 11" default
            CGSize(width: 834, height: 1210),  // portrait
            CGSize(width: 1376, height: 1032), // iPad Pro 13"
            CGSize(width: 1133, height: 744),  // iPad mini
            CGSize(width: 1408, height: 600),  // shortened (keyboard / window)
            CGSize(width: 700, height: 700),
        ]
        var streams = ParsecResolution.allCases
            .filter { $0 != .host }
            .map { CGSize(width: $0.width, height: $0.height) }
        streams += [
            CGSize(width: 3024, height: 1964), // MacBook Pro 14" host
            CGSize(width: 2560, height: 1664), // MacBook Air 13"
            CGSize(width: 5120, height: 1440), // 32:9
            CGSize(width: 1080, height: 1920), // portrait host
            CGSize(width: 2421, height: 1668), // client-sized
        ]
        for screen in screens {
            for stream in streams {
                let fit = ParsecResolution.aspectFit(stream, in: screen)
                let label = "\(stream) in \(screen)"
                // Never cropped: inside the view.
                XCTAssertGreaterThanOrEqual(fit.minX, -0.001, label)
                XCTAssertGreaterThanOrEqual(fit.minY, -0.001, label)
                XCTAssertLessThanOrEqual(fit.maxX, screen.width + 0.001, label)
                XCTAssertLessThanOrEqual(fit.maxY, screen.height + 0.001, label)
                // Never stretched: same aspect as the stream.
                XCTAssertEqual(fit.width / fit.height, stream.width / stream.height, accuracy: 1e-9, label)
                // As large as possible: fills one axis completely.
                XCTAssertTrue(
                    abs(fit.width - screen.width) < 0.001 || abs(fit.height - screen.height) < 0.001,
                    label
                )
                // Centred: equal bars on both sides.
                XCTAssertEqual(fit.minX, screen.width - fit.maxX, accuracy: 0.001, label)
                XCTAssertEqual(fit.minY, screen.height - fit.maxY, accuracy: 0.001, label)
            }
        }
    }

    func testAspectFitBarsGoOnTheRightAxis() {
        let view = CGSize(width: 1408, height: 970) // 1.45:1
        // Wider stream (21:9) → letterbox (bars top/bottom).
        let wide = ParsecResolution.aspectFit(CGSize(width: 3440, height: 1440), in: view)
        XCTAssertEqual(wide.minX, 0, accuracy: 0.001)
        XCTAssertGreaterThan(wide.minY, 0)
        // Narrower stream (4:3, 5:4) → pillarbox (bars left/right).
        for stream in [CGSize(width: 1024, height: 768), CGSize(width: 1280, height: 1024)] {
            let fit = ParsecResolution.aspectFit(stream, in: view)
            XCTAssertEqual(fit.minY, 0, accuracy: 0.001)
            XCTAssertGreaterThan(fit.minX, 0)
        }
    }

    func testAspectFitUnknownStreamOrEmptyViewUsesWholeBounds() {
        let view = CGSize(width: 1408, height: 970)
        // "Host Resolution" is 0x0 until the decoder reports a size.
        XCTAssertEqual(ParsecResolution.host.width, 0)
        XCTAssertEqual(ParsecResolution.aspectFit(.zero, in: view), CGRect(origin: .zero, size: view))
        XCTAssertEqual(ParsecResolution.aspectFit(CGSize(width: 1920, height: 1080), in: .zero), .zero)
    }

    func testClientResolutionIsEvenAndIgnoresEmptyViews() {
        let original = (ParsecResolution.client.width, ParsecResolution.client.height)
        defer { ParsecResolution.updateClientResolution(width: original.0, height: original.1) }
        // 1408 pt × 1.7196 = 2421 px: encoders need even sizes.
        ParsecResolution.updateClientResolution(width: 2421, height: 1668)
        XCTAssertEqual(ParsecResolution.client.width, 2420)
        XCTAssertEqual(ParsecResolution.client.height, 1668)
        // A not-yet-laid-out view (0x0) must not turn "Client" into "Host".
        ParsecResolution.updateClientResolution(width: 0, height: 0)
        XCTAssertEqual(ParsecResolution.client.width, 2420)
    }
}
