import XCTest

final class OpenParsecUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testApplicationLaunches() throws {
        let app = launch(scenario: "success")

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(
            app.buttons["openparsec.fake-host.connect"].waitForExistence(timeout: 10),
            "The deterministic main view did not become accessible"
        )
    }

    func testSuccessfulFakeConnectionReachesProductionSessionView() throws {
        let app = launch(scenario: "success")

        connectButton(in: app).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["openparsec.session"].waitForExistence(timeout: 10),
            "The successful fake session did not reach ParsecView"
        )
        assertSessionState("interactive", in: app)
        assertSessionDiagnostics(contains: "phase=interactive", in: app)
        assertSessionDiagnostics(contains: "video=true audio=true", in: app)
    }

    func testBlackFrameScenarioExposesMissingFirstFrame() throws {
        let app = launch(scenario: "blackFrame")

        connectButton(in: app).tap()

        assertSessionState("waiting-for-first-frame", in: app)
        assertSessionDiagnostics(contains: "video=false audio=true", in: app)
    }

    func testAudioStallScenarioStaysInteractiveWithoutAudio() throws {
        let app = launch(scenario: "audioStall")

        connectButton(in: app).tap()

        assertSessionState("interactive", in: app)
        assertSessionDiagnostics(contains: "video=true audio=false", in: app)
    }

    func testExpiredAuthShowsActionableMessageAndReturnsToSignIn() throws {
        let app = launch(
            scenario: "success",
            extraArguments: ["--api-failure=expired-auth"]
        )

        let message = app.alerts.staticTexts["Your session expired. Sign in again."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10))
    }

    func testMissingHostShowsActionableMessageWithoutStaleHost() throws {
        let app = launch(
            scenario: "success",
            extraArguments: ["--api-failure=missing-host"]
        )

        let message = app.alerts.staticTexts[
            "The requested host is no longer available. Refresh the host list."
        ]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openparsec.fake-host.connect"].exists)
    }

    func testActiveTransportDropReconnectsAutomaticallyWithoutSecondTap() throws {
        let app = launch(
            scenario: "transportRecovery",
            extraArguments: ["--background-reconnect-delay=0.1"]
        )

        connectButton(in: app).tap()
        assertElement(
            "openparsec.session.generation",
            hasLabel: "2",
            in: app,
            timeout: 15
        )
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.network-recovery.state",
            hasLabel: "monitoring",
            in: app,
            timeout: 10
        )
    }

    func testActiveTransportReconnectExhaustionStopsAtReplacementGeneration() throws {
        let app = launch(
            scenario: "transportReconnectExhaustion",
            extraArguments: ["--background-reconnect-delay=0.1"]
        )

        connectButton(in: app).tap()
        // The replacement (generation 2) plus seven reconnect retries all fail.
        XCTAssertTrue(failureAlert(containing: "(code -6023)", in: app).waitForExistence(timeout: 75))
        assertElement(
            "openparsec.session.generation",
            hasLabel: "9",
            in: app,
            timeout: 10
        )
        assertElement(
            "openparsec.recovery.state",
            hasLabel: "idle",
            in: app,
            timeout: 10
        )
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(
            app.descendants(matching: .any)["openparsec.session.generation"].label,
            "9"
        )
    }

    func testCancellingPendingTransportReconnectPreventsAnotherAttempt() throws {
        let app = launch(
            scenario: "transportReconnectPending",
            extraArguments: ["--background-reconnect-delay=0.1"]
        )

        connectButton(in: app).tap()
        let pending = app.descendants(matching: .any)["openparsec.connection.pending"]
        XCTAssertTrue(pending.waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()

        let hidden = NSPredicate(format: "exists == false")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: hidden, object: pending)],
                timeout: 10
            ),
            .completed
        )
        assertElement(
            "openparsec.session.generation",
            hasLabel: "2",
            in: app,
            timeout: 10
        )
        assertSessionDiagnostics(contains: "phase=disconnected", in: app)
    }

    func testTimeoutScenarioShowsActionableFailure() throws {
        let app = launch(scenario: "timeout")

        connectButton(in: app).tap()

        XCTAssertTrue(
            failureAlert(containing: "(code -6023)", in: app).waitForExistence(timeout: 45),
            "The timeout status was not surfaced to the user after transient retries"
        )
        // The runner closes the failed SDK session after its last retry; the
        // failure itself is kept as lastFailure.
        assertSessionDiagnostics(contains: "phase=disconnected", in: app)
        assertSessionDiagnostics(contains: "lastFailure=-6023@transport", in: app)
    }

    // A transient network failure (-6023/-6013 class) is retried by the
    // connect runner without a second tap and without an alert.
    func testTransientConnectFailureRetriesAutomatically() throws {
        let app = launch(scenario: "reconnect")
        connectButton(in: app).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["openparsec.session"].waitForExistence(timeout: 15),
            "The automatic retry did not recover"
        )
        XCTAssertFalse(app.alerts.element.exists)
        assertSessionState("interactive", in: app)
        assertSessionDiagnostics(contains: "generation=2", in: app)
    }

    func testMediaWatchdogReconnectsSamePeerWithoutTap() throws {
        let app = launch(
            scenario: "mediaRecovery",
            extraArguments: mediaRecoveryArguments
        )
        connectButton(in: app).tap()

        assertElement(
            "openparsec.session.generation",
            hasLabel: "2",
            in: app,
            timeout: 15
        )
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.media-recovery.state",
            hasLabel: "recovered",
            in: app,
            timeout: 10
        )
    }

    func testBlackFrameExhaustionShowsTerminalVideoDiagnosticWithoutLoop() throws {
        let app = launch(
            scenario: "reconnectExhaustion",
            extraArguments: mediaRecoveryArguments
        )
        connectButton(in: app).tap()

        XCTAssertTrue(
            app.alerts.staticTexts[
                "Video did not recover after one automatic reconnect (code -7101)."
            ].waitForExistence(timeout: 15)
        )
        assertElement(
            "openparsec.session.generation",
            hasLabel: "2",
            in: app,
            timeout: 10
        )
        assertElement(
            "openparsec.media-recovery.state",
            hasLabel: "terminal-failure",
            in: app,
            timeout: 10
        )
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(
            app.descendants(matching: .any)["openparsec.session.generation"].label,
            "2"
        )
    }

    func testRendererFailurePreservesRawCodeInTerminalDiagnostic() throws {
        let app = launch(
            scenario: "rendererFailure",
            extraArguments: mediaRecoveryArguments
        )
        connectButton(in: app).tap()

        XCTAssertTrue(
            app.alerts.staticTexts[
                "Video did not recover after one automatic reconnect (code -7001)."
            ].waitForExistence(timeout: 15)
        )
        assertSessionDiagnostics(contains: "lastFailure=-7001@video", in: app)
    }

    func testPointerModesExposeNativeAndCapturedOwnership() throws {
        let nativeApp = launch(
            scenario: "success",
            extraArguments: ["--pointer-mode=native"]
        )
        connectButton(in: nativeApp).tap()
        assertSessionState("interactive", in: nativeApp)
        assertElement(
            "openparsec.pointer.state",
            hasLabel: "native",
            in: nativeApp,
            timeout: 10
        )
        assertElement(
            "openparsec.pointer.diagnostics",
            hasLabel: "mode=native lock=false route=absolute cursor=host",
            in: nativeApp,
            timeout: 10
        )
        nativeApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertElement(
            "openparsec.mouse-buttons.diagnostics",
            hasLabel: "pressed=0 release=normal",
            in: nativeApp,
            timeout: 10
        )
        nativeApp.terminate()

        let capturedApp = launch(
            scenario: "success",
            extraArguments: ["--pointer-mode=captured"]
        )
        connectButton(in: capturedApp).tap()
        assertSessionState("interactive", in: capturedApp)
        assertElement(
            "openparsec.pointer.state",
            hasLabel: "captured",
            in: capturedApp,
            timeout: 10
        )
        assertElement(
            "openparsec.pointer.diagnostics",
            hasLabel: "mode=captured lock=true route=relative cursor=local",
            in: capturedApp,
            timeout: 10
        )
    }

    func testBackgroundReleasesHeldKeyboardState() throws {
        let app = launch(
            scenario: "success",
            extraArguments: [
                "--hold-test-key",
                "--disable-pip",
                "--background-grace=5"
            ]
        )
        connectButton(in: app).tap()
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.keyboard.state",
            hasLabel: "1",
            in: app,
            timeout: 10
        )

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 0.2)
        app.activate()

        assertElement(
            "openparsec.keyboard.state",
            hasLabel: "0",
            in: app,
            timeout: 10
        )
        // Leaving the foreground releases the key; whether focus loss or the
        // background transition gets there first depends on the runner.
        let diagnostics = app.descendants(matching: .any)["openparsec.keyboard.diagnostics"]
        let released = NSPredicate(
            format: "label MATCHES %@",
            "generation=1 pressed=0 repeats=0 release=(background|focus-lost)"
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: released, object: diagnostics)], timeout: 10),
            .completed,
            "Expected the held key released on leaving foreground, got \(diagnostics.label)"
        )
    }

    func testWindowsRawMacroExecutesInCommandAsControlMode() throws {
        let app = launch(
            scenario: "success",
            extraArguments: [
                "--windows-mode=command-as-control",
                "--mac-shortcuts=true",
                "--execute-test-windows-shortcut"
            ]
        )
        connectButton(in: app).tap()
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.windows.mode",
            hasLabel: "command-as-control",
            in: app,
            timeout: 10
        )
        assertElement(
            "openparsec.windows.diagnostics",
            hasLabel: "mode=command-as-control buttons=true coverage=10",
            in: app,
            timeout: 10
        )
        assertElement(
            "openparsec.shortcuts.diagnostics",
            hasLabel: "enabled=true coverage=14 completed=1 route=explicit-macro",
            in: app,
            timeout: 10
        )
        assertElement(
            "openparsec.keyboard.state",
            hasLabel: "0",
            in: app,
            timeout: 10
        )
    }

    func testGamepadInputReleasesWithoutStuckButtonThroughProductionPath() throws {
        let app = launch(
            scenario: "success",
            extraArguments: [
                "--execute-test-gamepad-input"
            ]
        )
        connectButton(in: app).tap()
        assertSessionState("interactive", in: app)
        // The production hook pressed a supported button, an unsupported
        // button, and deflected a stick, then released everything. The host
        // must see zero held buttons afterward.
        assertElement(
            "openparsec.gamepad.state",
            hasLabel: "0",
            in: app,
            timeout: 10
        )
    }

    func testSettingsContractDiagnosticsReflectAppliedSetting() throws {
        let app = launch(
            scenario: "success",
            extraArguments: [
                "--mac-shortcuts=false"
            ]
        )
        connectButton(in: app).tap()
        assertSessionState("interactive", in: app)
        // The contract coverage count is wired into the running app.
        assertElement(
            "openparsec.settings.coverage",
            hasLabel: "30",
            in: app,
            timeout: 10
        )
        // A launch-arg override flows through the settings model into the
        // content-free settings diagnostics surface.
        assertElement(
            "openparsec.settings.diagnostics",
            hasLabel: "count=30 visible=25 toolbar=windows",
            in: app,
            timeout: 10
        )
    }

    func testConcurrencyDiagnosticsReflectCleanFakeConnectCycle() throws {
        let app = launch(scenario: "success")
        connectButton(in: app).tap()

        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.concurrency.state",
            hasLabel: "generation=1 input=0 buffers=0 timers=0 observers=0 cycles=1",
            in: app,
            timeout: 10
        )
    }

    func testMacShortcutAlternativeExecutesBoundedChord() throws {
        let app = launch(
            scenario: "success",
            extraArguments: [
                "--mac-shortcuts=true",
                "--execute-test-mac-shortcut"
            ]
        )
        connectButton(in: app).tap()
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.shortcuts.state",
            hasLabel: "enabled",
            in: app,
            timeout: 10
        )
        assertElement(
            "openparsec.shortcuts.diagnostics",
            hasLabel: "enabled=true coverage=14 completed=1 route=explicit-macro",
            in: app,
            timeout: 10
        )
        assertElement(
            "openparsec.keyboard.state",
            hasLabel: "0",
            in: app,
            timeout: 10
        )
    }

    func testQuickBackgroundReturnPreservesGenerationWithoutReconnect() throws {
        let app = launch(
            scenario: "success",
            extraArguments: [
                "--disable-pip",
                "--background-grace=5",
                "--background-reconnect-delay=0.1"
            ]
        )
        connectButton(in: app).tap()
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.session.generation",
            hasLabel: "1",
            in: app,
            timeout: 10
        )

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 0.2)
        app.activate()

        assertElement(
            "openparsec.session.generation",
            hasLabel: "1",
            in: app,
            timeout: 10
        )
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.recovery.state",
            hasLabel: "idle",
            in: app,
            timeout: 10
        )
    }

    func testForcedBackgroundExpiryReconnectsWithoutConnectTap() throws {
        let app = launch(
            scenario: "success",
            extraArguments: [
                "--disable-pip",
                "--background-grace=0.2",
                "--background-reconnect-delay=1.0"
            ]
        )
        connectButton(in: app).tap()
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.session.generation",
            hasLabel: "1",
            in: app,
            timeout: 10
        )

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()

        let session = app.descendants(matching: .any)["openparsec.session"]
        XCTAssertTrue(
            session.waitForExistence(timeout: 0.5),
            "Automatic reconnect must keep the session presentation visible instead of flashing the host menu"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["openparsec.fake-host.connect"].exists,
            "The host menu must stay hidden while automatic reconnect is pending"
        )

        assertElement(
            "openparsec.session.generation",
            hasLabel: "2",
            in: app,
            timeout: 15
        )
        assertSessionState("interactive", in: app)
        assertElement(
            "openparsec.recovery.state",
            hasLabel: "idle",
            in: app,
            timeout: 10
        )
    }

    private var mediaRecoveryArguments: [String] {
        [
            "--media-soft-deadline=0.1",
            "--media-hard-deadline=0.3",
            "--background-reconnect-delay=0.1"
        ]
    }

    private func assertSessionState(_ expected: String, in app: XCUIApplication) {
        let state = app.descendants(matching: .any)["openparsec.session.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The session readiness state was not exposed")
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: state)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10),
            .completed,
            "Expected session state \(expected), got \(state.label)"
        )
    }

    private func assertSessionDiagnostics(contains expected: String, in app: XCUIApplication) {
        let diagnostics = app.descendants(matching: .any)["openparsec.session.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10), "The session diagnostics digest was not exposed")
        XCTAssertTrue(
            diagnostics.label.contains(expected),
            "Expected diagnostics to contain '\(expected)', got '\(diagnostics.label)'"
        )
    }

    private func assertElement(
        _ identifier: String,
        hasLabel expected: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(identifier)")
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected \(identifier) label \(expected), got \(element.label)"
        )
    }

    private func failureAlert(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func launch(
        scenario: String,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--fake-scenario=\(scenario)"] + extraArguments
        app.launch()
        return app
    }

    private func connectButton(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["openparsec.fake-host.connect"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The injected fake host was not available")
        return button
    }
}
