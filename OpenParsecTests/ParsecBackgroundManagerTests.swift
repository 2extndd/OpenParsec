import XCTest
@testable import OpenParsec

final class ParsecBackgroundManagerTests: XCTestCase {
    func testRecoverySnapshotsExposeSafeReactiveStateAndGeneration() {
        let harness = makeHarness()
        var snapshots: [ParsecRecoverySnapshot] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .parsecRecoveryStateDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if let snapshot = notification.object as? ParsecRecoverySnapshot {
                snapshots.append(snapshot)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        harness.manager.connectionDidStart(peerId: "private-peer", generation: 7)
        harness.manager.beginBackgroundGrace()
        harness.scheduler.runAllActive()

        XCTAssertEqual(snapshots.map(\.state), ["idle", "grace", "reconnect-pending"])
        XCTAssertEqual(snapshots.map(\.generation), [7, 7, 7])
        XCTAssertFalse(snapshots.map(\.digest).joined().contains("private-peer"))
    }

    func testBeginGraceCreatesOneAssertionAndOneTimer() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        harness.manager.beginBackgroundGrace()
        harness.manager.beginBackgroundGrace()

        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertTrue(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.session.enterGraceCount, 1)
        XCTAssertEqual(harness.assertions.beginCount, 1)
        XCTAssertEqual(harness.scheduler.activeCount, 1)
        XCTAssertEqual(harness.scheduler.activeDelays, [20])
    }

    // With the audio queue playing, iPadOS keeps the process alive: no 30 s
    // task assertion, and the session survives a long app switch.
    func testAudioKeepAliveSkipsAssertionAndUsesLongCap() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        harness.manager.sceneDidEnterBackground(pipProtected: false, audioKeepAlive: true)

        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertEqual(harness.assertions.beginCount, 0)
        XCTAssertEqual(harness.scheduler.activeDelays, [600])
        harness.manager.sceneDidBecomeActive()
        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertTrue(harness.session.disconnectReasons.isEmpty)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
    }

    func testForegroundInsideGraceKeepsConnectionAndCancelsEffects() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.manager.sceneDidBecomeActive()
        harness.scheduler.runAllActive()

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertTrue(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.session.resumeCount, 1)
        XCTAssertEqual(harness.session.disconnectReasons, [])
        XCTAssertEqual(harness.assertions.endCount, 1)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
        XCTAssertEqual(harness.reconnects, [])
    }

    func testGraceTimerDisconnectsOnceAndForegroundReconnectsSamePeerOnce() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.scheduler.runNextActive()

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
        XCTAssertFalse(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.session.disconnectReasons, [.backgroundExpired])
        XCTAssertEqual(harness.disconnectNotifications, 1)
        XCTAssertEqual(harness.assertions.endCount, 1)

        harness.manager.sceneDidBecomeActive()
        harness.manager.sceneDidBecomeActive()
        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-scheduled")
        XCTAssertEqual(harness.scheduler.activeDelays, [0.5])

        harness.scheduler.runAllActive()
        harness.manager.sceneDidBecomeActive()
        harness.scheduler.runAllActive()
        XCTAssertEqual(harness.reconnects, ["peer-1"])
    }

    func testActiveTransportRecoverySchedulesPendingReconnectExactlyOnce() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 3)
        harness.manager.connectionDidEnd(
            generation: 3,
            reason: .transportFailure
        )

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
        harness.manager.schedulePendingReconnect()
        harness.manager.schedulePendingReconnect()

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-scheduled")
        XCTAssertEqual(harness.scheduler.activeDelays, [0.5])
        harness.scheduler.runAllActive()
        XCTAssertEqual(harness.reconnects, ["peer-1"])
    }

    func testDecoderRecoveryPreservesPresentationUntilReplacementStarts() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 3)
        harness.manager.preserveSessionPresentation(generation: 2)
        XCTAssertFalse(harness.manager.shouldPreserveSessionPresentation)

        harness.manager.preserveSessionPresentation(generation: 3)
        harness.manager.connectionDidEnd(generation: 3, reason: .transportFailure)
        XCTAssertTrue(harness.manager.shouldPreserveSessionPresentation)
        XCTAssertTrue(harness.manager.isMarkedForReconnect)

        harness.manager.connectionDidStart(peerId: "peer-1", generation: 4)
        XCTAssertFalse(harness.manager.shouldPreserveSessionPresentation)
    }

    func testDisableAutoReconnectCancelsScheduledActiveRecovery() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 3)
        harness.manager.connectionDidEnd(
            generation: 3,
            reason: .transportFailure
        )
        harness.manager.schedulePendingReconnect()

        XCTAssertEqual(harness.scheduler.activeCount, 1)
        harness.manager.disableAutoReconnect()
        harness.scheduler.runAllActive()

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertEqual(harness.scheduler.activeCount, 0)
        XCTAssertTrue(harness.reconnects.isEmpty)
    }

    func testOSExpirationAndTimerCallbackCannotDoubleDisconnect() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.assertions.expireLatest()
        harness.scheduler.forceRun(index: 0)

        XCTAssertEqual(harness.session.disconnectReasons, [.backgroundExpired])
        XCTAssertEqual(harness.disconnectNotifications, 1)
        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
    }

    func testDeniedBackgroundAssertionFallsBackToImmediateDisconnect() {
        let harness = makeHarness()
        harness.assertions.grantsAssertion = false
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        harness.manager.beginBackgroundGrace()

        XCTAssertEqual(harness.session.disconnectReasons, [.backgroundExpired])
        XCTAssertEqual(harness.disconnectNotifications, 1)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
    }

    func testStaleTimerFromPriorGraceCannotDisconnectNewGrace() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()
        harness.manager.sceneDidBecomeActive()

        harness.manager.beginBackgroundGrace()
        harness.scheduler.forceRun(index: 0)

        XCTAssertTrue(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertTrue(harness.session.disconnectReasons.isEmpty)

        harness.scheduler.forceRun(index: 1)
        XCTAssertEqual(harness.session.disconnectReasons, [.backgroundExpired])
    }

    func testDisableAutoReconnectCancelsGraceAndPendingRecovery() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.manager.disableAutoReconnect()
        harness.scheduler.forceRun(index: 0)
        harness.manager.sceneDidBecomeActive()
        harness.scheduler.runAllActive()

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertFalse(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.assertions.endCount, 1)
        XCTAssertTrue(harness.session.disconnectReasons.isEmpty)
        XCTAssertTrue(harness.reconnects.isEmpty)
    }

    func testBackgroundPresentationMarkerClearsOnHealthyForegroundTransport() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.sceneDidEnterBackground(pipProtected: false)

        XCTAssertTrue(harness.manager.shouldPreserveSessionPresentation)
        harness.manager.foregroundTransportRemainedUsable(generation: 1)
        XCTAssertFalse(harness.manager.shouldPreserveSessionPresentation)
    }

    func testBackgroundPresentationMarkerClearsWhenReplacementStarts() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.sceneDidEnterBackground(pipProtected: false)

        XCTAssertTrue(harness.manager.shouldPreserveSessionPresentation)
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 2)
        XCTAssertFalse(harness.manager.shouldPreserveSessionPresentation)
    }

    func testConfirmedPiPStartCancelsProvisionalGrace() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.sceneDidEnterBackground(pipProtected: false)

        harness.manager.pictureInPictureDidStart(generation: 1)

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertEqual(harness.scheduler.activeCount, 0)
        XCTAssertEqual(harness.assertions.endCount, 1)
        XCTAssertEqual(harness.session.enterBackgroundCount, 2)
    }

    func testStalePiPStartCannotCancelReplacementGrace() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-new", generation: 2)
        harness.manager.sceneDidEnterBackground(pipProtected: false)

        harness.manager.pictureInPictureDidStart(generation: 1)

        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertEqual(harness.scheduler.activeCount, 1)
        XCTAssertEqual(harness.assertions.endCount, 0)
    }

    func testPiPProtectionLossInBackgroundFallsBackToOneGraceWindow() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        harness.manager.pictureInPictureProtectionEnded(
            whileBackgrounded: true,
            generation: 1
        )
        harness.manager.pictureInPictureProtectionEnded(
            whileBackgrounded: true,
            generation: 1
        )

        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertEqual(harness.session.enterGraceCount, 1)
        XCTAssertEqual(harness.assertions.beginCount, 1)
        XCTAssertEqual(harness.scheduler.activeCount, 1)
    }

    func testPiPProtectionLossInForegroundDoesNotOpenGrace() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        harness.manager.pictureInPictureProtectionEnded(
            whileBackgrounded: false,
            generation: 1
        )

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertEqual(harness.session.enterGraceCount, 0)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
    }

    func testStalePiPCallbackCannotOpenGraceForReplacementGeneration() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-old", generation: 1)
        harness.manager.connectionDidStart(peerId: "peer-new", generation: 2)

        harness.manager.pictureInPictureProtectionEnded(
            whileBackgrounded: true,
            generation: 1
        )

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertEqual(harness.session.enterGraceCount, 0)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
    }

    func testUnusableTransportDisconnectsAndNotifiesExactlyOnce() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        XCTAssertTrue(harness.manager.transportBecameUnusable(generation: 1))
        XCTAssertFalse(harness.manager.transportBecameUnusable(generation: 1))

        XCTAssertEqual(harness.session.disconnectReasons, [.transportFailure])
        XCTAssertEqual(harness.session.disconnectGenerations, [1])
        XCTAssertEqual(harness.disconnectNotifications, 1)
        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
    }

    func testExplicitConnectionEndCancelsGraceWithoutRecovery() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.manager.connectionDidEnd(generation: 1, reason: .user)

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertFalse(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
        XCTAssertEqual(harness.assertions.endCount, 1)
        XCTAssertEqual(harness.disconnectNotifications, 0)
    }

    func testImmediateReconnectFailurePreservesPeerForForegroundRetry() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 2)

        harness.manager.connectionAttemptDidFail(
            peerID: "peer-1",
            generation: 2,
            intent: .reconnect
        )

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
        XCTAssertFalse(harness.manager.hasActiveConnection)
        XCTAssertTrue(harness.session.disconnectReasons.isEmpty)
    }

    func testReconnectAttemptFailureReturnsToPendingExactlyOnce() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 2)

        harness.manager.reconnectAttemptDidFail(peerID: "peer-1", generation: 2)
        harness.manager.reconnectAttemptDidFail(peerID: "peer-1", generation: 2)

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
        XCTAssertFalse(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.session.disconnectReasons, [.transportFailure])
        XCTAssertEqual(harness.session.disconnectGenerations, [2])
    }

    func testStaleReconnectFailureCannotAffectReplacementGeneration() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-old", generation: 1)
        harness.manager.connectionDidStart(peerId: "peer-new", generation: 2)

        harness.manager.reconnectAttemptDidFail(peerID: "peer-old", generation: 1)

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertTrue(harness.manager.hasActiveConnection)
        XCTAssertTrue(harness.session.disconnectReasons.isEmpty)
    }

    func testStaleConnectionStartCannotOverwriteNewerGeneration() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-new", generation: 2)
        harness.manager.connectionDidStart(peerId: "peer-stale", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.scheduler.runAllActive()

        XCTAssertEqual(harness.session.disconnectGenerations, [2])
    }

    func testStaleConnectionEndCannotClearNewerGrace() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-new", generation: 2)
        harness.manager.beginBackgroundGrace()

        harness.manager.connectionDidEnd(generation: 1)

        XCTAssertTrue(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertEqual(harness.scheduler.activeCount, 1)
        XCTAssertEqual(harness.assertions.endCount, 0)
    }

    func testConnectionStartDuringInFlightGraceSetupKeepsTokenBoundResources() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.assertions.onBegin = {
            harness.assertions.onBegin = nil
            harness.manager.connectionDidStart(peerId: "peer-2", generation: 2)
        }

        harness.manager.beginBackgroundGrace()

        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertEqual(harness.session.enterGraceCount, 2)
        XCTAssertEqual(harness.assertions.beginCount, 2)
        XCTAssertEqual(harness.scheduler.activeCount, 1)
        XCTAssertEqual(harness.assertions.endCount, 1)

        harness.scheduler.runAllActive()
        XCTAssertEqual(harness.session.disconnectGenerations, [2])
    }

    func testNewConnectionBetweenExpiryClaimAndDisconnectRejectsStaleTeardown() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()
        harness.session.disconnectHandler = { _, generation in
            harness.manager.connectionDidStart(peerId: "peer-2", generation: 2)
            return generation == 2
        }

        harness.scheduler.runAllActive()

        XCTAssertEqual(harness.session.disconnectGenerations, [1])
        XCTAssertEqual(harness.disconnectNotifications, 0)
        XCTAssertTrue(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
    }

    func testMarkForReconnectCancelsAlreadyScheduledCallback() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()
        harness.scheduler.runNextActive()
        harness.manager.sceneDidBecomeActive()
        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-scheduled")

        harness.manager.markForReconnect()
        harness.scheduler.runAllActive()

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
        XCTAssertTrue(harness.reconnects.isEmpty)
    }

    func testConnectionStartDuringGracePreservesGraceResources() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        XCTAssertEqual(harness.manager.recoveryStateName, "grace")
        XCTAssertEqual(harness.scheduler.activeCount, 1)
        XCTAssertEqual(harness.assertions.endCount, 0)

        harness.manager.sceneDidBecomeActive()
        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertEqual(harness.assertions.endCount, 1)
    }

    func testConnectionEndDuringGraceCleansResourcesAndQueuesReconnect() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()

        harness.manager.connectionDidEnd(generation: 1)

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
        XCTAssertFalse(harness.manager.hasActiveConnection)
        XCTAssertEqual(harness.assertions.endCount, 1)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
        XCTAssertEqual(harness.disconnectNotifications, 1)

        harness.manager.sceneDidBecomeActive()
        harness.scheduler.runAllActive()
        XCTAssertEqual(harness.reconnects, ["peer-1"])
    }

    func testSynchronousAssertionExpirationDoesNotLeakReturnedToken() {
        let harness = makeHarness()
        harness.assertions.expiresSynchronously = true
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)

        harness.manager.beginBackgroundGrace()

        XCTAssertEqual(harness.manager.recoveryStateName, "reconnect-pending")
        XCTAssertEqual(harness.session.disconnectReasons, [.backgroundExpired])
        XCTAssertEqual(harness.assertions.endCount, 1)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
    }

    func testConnectionStartCancelsScheduledReconnect() {
        let harness = makeHarness()
        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.manager.beginBackgroundGrace()
        harness.scheduler.runNextActive()
        harness.manager.sceneDidBecomeActive()

        harness.manager.connectionDidStart(peerId: "peer-1", generation: 1)
        harness.scheduler.runAllActive()

        XCTAssertEqual(harness.manager.recoveryStateName, "idle")
        XCTAssertTrue(harness.manager.hasActiveConnection)
        XCTAssertTrue(harness.reconnects.isEmpty)
    }

    private func makeHarness() -> BackgroundHarness {
        let scheduler = TestBackgroundScheduler()
        let assertions = TestBackgroundAssertionProvider()
        let session = TestBackgroundSessionController()
        let manager = ParsecBackgroundManager(
            backgroundTasks: assertions,
            scheduler: scheduler,
            session: session,
            gracePeriod: 20,
            reconnectDelay: 0.5
        )
        let harness = BackgroundHarness(
            manager: manager,
            scheduler: scheduler,
            assertions: assertions,
            session: session
        )
        manager.onShouldReconnect = { harness.reconnects.append($0.peerID) }
        manager.onShouldDisconnect = { harness.disconnectNotifications += 1 }
        return harness
    }
}

private final class BackgroundHarness {
    let manager: ParsecBackgroundManager
    let scheduler: TestBackgroundScheduler
    let assertions: TestBackgroundAssertionProvider
    let session: TestBackgroundSessionController
    var reconnects: [String] = []
    var disconnectNotifications = 0

    init(
        manager: ParsecBackgroundManager,
        scheduler: TestBackgroundScheduler,
        assertions: TestBackgroundAssertionProvider,
        session: TestBackgroundSessionController
    ) {
        self.manager = manager
        self.scheduler = scheduler
        self.assertions = assertions
        self.session = session
    }
}

private final class TestBackgroundSessionController: ParsecBackgroundSessionControlling {
    var enterBackgroundCount = 0
    var enterGraceCount = 0
    var resumeCount = 0
    var disconnectReasons: [ParsecDisconnectReason] = []
    var disconnectGenerations: [UInt64] = []
    var disconnectHandler: ((ParsecDisconnectReason, UInt64) -> Bool)?

    func enterBackground() { enterBackgroundCount += 1 }
    func enterBackgroundGrace() { enterGraceCount += 1 }
    func resumeForeground() { resumeCount += 1 }
    @discardableResult
    func disconnect(reason: ParsecDisconnectReason, generation: UInt64) -> Bool {
        disconnectReasons.append(reason)
        disconnectGenerations.append(generation)
        return disconnectHandler?(reason, generation) ?? true
    }
}

private final class TestBackgroundAssertionProvider: BackgroundTaskAssertionProviding {
    var grantsAssertion = true
    var expiresSynchronously = false
    var onBegin: (() -> Void)?
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var nextRawValue = 1
    private var expirations: [() -> Void] = []

    func begin(name: String, expiration: @escaping () -> Void) -> BackgroundTaskToken? {
        beginCount += 1
        expirations.append(expiration)
        onBegin?()
        guard grantsAssertion else { return nil }
        defer { nextRawValue += 1 }
        let token = BackgroundTaskToken(rawValue: nextRawValue)
        if expiresSynchronously {
            expiration()
        }
        return token
    }

    func end(_ token: BackgroundTaskToken) {
        endCount += 1
    }

    func expireLatest() {
        expirations.last?()
    }
}

private final class TestBackgroundScheduler: BackgroundLifecycleScheduling {
    private final class Entry {
        let delay: TimeInterval
        let task = TestScheduledTask()
        let action: () -> Void
        var fired = false

        init(delay: TimeInterval, action: @escaping () -> Void) {
            self.delay = delay
            self.action = action
        }
    }

    private var entries: [Entry] = []

    var activeCount: Int {
        entries.filter { !$0.task.isCancelled && !$0.fired }.count
    }

    var activeDelays: [TimeInterval] {
        entries.filter { !$0.task.isCancelled && !$0.fired }.map(\.delay)
    }

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> BackgroundScheduledTask {
        let entry = Entry(delay: delay, action: action)
        entries.append(entry)
        return entry.task
    }

    func runNextActive() {
        guard let entry = entries.first(where: { !$0.task.isCancelled && !$0.fired }) else { return }
        entry.fired = true
        entry.action()
    }

    func runAllActive() {
        while entries.contains(where: { !$0.task.isCancelled && !$0.fired }) {
            runNextActive()
        }
    }

    func forceRun(index: Int) {
        guard entries.indices.contains(index), !entries[index].fired else { return }
        entries[index].fired = true
        entries[index].action()
    }
}

private final class TestScheduledTask: BackgroundScheduledTask {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
