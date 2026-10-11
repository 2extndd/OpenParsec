import XCTest
@testable import OpenParsec

final class ParsecMediaRecoveryTests: XCTestCase {
    func testReadinessBeforeDeadlinesCancelsAllRecovery() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))

        harness.coordinator.observe(snapshot(generation: 1, media: .ready))
        harness.scheduler.runAllIncludingCancelled()

        XCTAssertTrue(harness.actions.isEmpty)
        XCTAssertEqual(harness.coordinator.snapshot.phase, .recovered)
        XCTAssertEqual(harness.scheduler.activeCount, 0)
    }

    func testMissingVideoRequestsOneSurfaceResumeThenOneReconnect() {
        let harness = makeHarness()
        harness.coordinator.observe(
            snapshot(
                generation: 1,
                media: ParsecMediaReadiness(video: false, audio: true)
            )
        )

        harness.scheduler.run(delay: 3)
        harness.scheduler.run(delay: 3)
        XCTAssertEqual(harness.actions, [.resumeVideoSurface(generation: 1)])

        harness.scheduler.run(delay: 10)
        XCTAssertEqual(
            harness.actions,
            [.resumeVideoSurface(generation: 1), .reconnect(generation: 1)]
        )
        XCTAssertEqual(harness.coordinator.snapshot.phase, .reconnectRequested)
    }

    func testRendererFailureAfterFirstFrameStartsVideoRecovery() {
        let harness = makeHarness()
        let evidence = ParsecMediaEvidence(
            readiness: .ready,
            videoStatus: RemoteStatus(rawValue: -7001),
            audioStatus: .ok
        )

        harness.coordinator.observe(
            snapshot(generation: 5, phase: .interactive, media: .ready),
            evidence: evidence
        )
        harness.scheduler.run(delay: 3)

        XCTAssertEqual(harness.actions, [.resumeVideoSurface(generation: 5)])
        XCTAssertEqual(harness.coordinator.snapshot.missing, .video)
    }

    // A silent or headless host may never send an audio packet; that must not
    // tear down a session whose video is live.
    func testMissingAudioWithLiveVideoNeverReconnects() {
        let harness = makeHarness()
        harness.coordinator.observe(
            snapshot(
                generation: 4,
                media: ParsecMediaReadiness(video: true, audio: false)
            )
        )

        harness.scheduler.run(delay: 3)
        XCTAssertTrue(harness.actions.isEmpty)

        harness.scheduler.run(delay: 10)
        XCTAssertTrue(harness.actions.isEmpty)
    }

    func testReplacementGenerationExhaustionFailsVideoWithoutReconnectLoop() {
        let harness = makeHarness()
        harness.coordinator.observe(
            snapshot(
                generation: 1,
                media: ParsecMediaReadiness(video: false, audio: true)
            )
        )
        harness.scheduler.run(delay: 10)
        XCTAssertEqual(harness.actions, [.reconnect(generation: 1)])

        harness.coordinator.observe(
            snapshot(
                generation: 2,
                intent: .reconnect,
                media: ParsecMediaReadiness(video: false, audio: true)
            )
        )
        harness.scheduler.run(delay: 10)
        harness.scheduler.runAllIncludingCancelled()

        XCTAssertEqual(
            harness.actions,
            [.reconnect(generation: 1), .terminalFailure(generation: 2, stage: .video)]
        )
        XCTAssertEqual(harness.coordinator.snapshot.phase, .terminalFailure)
    }

    func testTransportDisconnectBetweenRequestAndReplacementPreservesBudget() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))
        harness.scheduler.run(delay: 10)

        harness.coordinator.observe(
            snapshot(
                generation: 1,
                phase: .disconnected,
                media: .notReady,
                disconnectReason: .transportFailure
            )
        )
        XCTAssertEqual(harness.coordinator.snapshot.phase, .reconnectRequested)

        harness.coordinator.observe(
            snapshot(generation: 2, intent: .reconnect, media: .notReady)
        )
        harness.scheduler.run(delay: 10)

        XCTAssertEqual(
            harness.actions,
            [.reconnect(generation: 1), .terminalFailure(generation: 2, stage: .video)]
        )
    }

    func testStaleDeadlinesCannotAffectReplacementGeneration() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))
        let staleTasks = harness.scheduler.tasks

        harness.coordinator.observe(
            snapshot(generation: 2, intent: .initial, media: .ready)
        )
        staleTasks.forEach { $0.runIgnoringCancellation() }

        XCTAssertTrue(harness.actions.isEmpty)
        XCTAssertEqual(harness.coordinator.snapshot.generation, 2)
        XCTAssertEqual(harness.coordinator.snapshot.phase, .recovered)
    }

    func testUnrelatedInitialGenerationResetsReconnectBudget() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))
        harness.scheduler.run(delay: 10)

        harness.coordinator.observe(
            snapshot(generation: 9, intent: .initial, media: .notReady)
        )
        harness.scheduler.run(delay: 10)

        XCTAssertEqual(
            harness.actions,
            [.reconnect(generation: 1), .reconnect(generation: 9)]
        )
    }

    func testExplicitCancelResetsReconnectBudget() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))
        harness.scheduler.run(delay: 10)
        harness.coordinator.cancel()

        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))
        harness.scheduler.run(delay: 10)

        XCTAssertEqual(
            harness.actions,
            [.reconnect(generation: 1), .reconnect(generation: 1)]
        )
    }

    func testTerminalFailurePersistsWhenSessionSnapshotBecomesFailed() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))
        harness.scheduler.run(delay: 10)
        harness.coordinator.observe(
            snapshot(generation: 2, intent: .reconnect, media: .notReady)
        )
        harness.scheduler.run(delay: 10)

        harness.coordinator.observe(
            snapshot(generation: 2, phase: .failed, intent: .reconnect, media: .notReady)
        )

        XCTAssertEqual(harness.coordinator.snapshot.phase, .terminalFailure)
        XCTAssertTrue(harness.coordinator.snapshot.reconnectUsed)
    }

    func testBackgroundAndDisconnectCancelPendingDeadlines() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 1, media: .notReady))

        harness.coordinator.observe(
            snapshot(generation: 1, phase: .backgroundGrace, media: .notReady)
        )
        harness.scheduler.runAllIncludingCancelled()

        XCTAssertTrue(harness.actions.isEmpty)
        XCTAssertEqual(harness.coordinator.snapshot.phase, .idle)
    }

    func testSynchronousSoftDeadlineDoesNotLeakReturnedTask() {
        let scheduler = MediaRecoveryTestScheduler(synchronousDelays: [3])
        let harness = makeHarness(scheduler: scheduler)

        harness.coordinator.observe(
            snapshot(
                generation: 3,
                media: ParsecMediaReadiness(video: false, audio: true)
            )
        )

        XCTAssertEqual(harness.actions, [.resumeVideoSurface(generation: 3)])
        XCTAssertEqual(scheduler.activeTasks(delay: 3), 0)
        XCTAssertEqual(scheduler.activeTasks(delay: 10), 1)
    }

    func testRecoveryDigestNeverContainsPeerOrCredentialData() {
        let harness = makeHarness()
        harness.coordinator.observe(snapshot(generation: 42, media: .notReady))

        let digest = harness.coordinator.snapshot.digest
        XCTAssertTrue(digest.contains("generation=42"))
        XCTAssertFalse(digest.contains("private-peer"))
        XCTAssertFalse(digest.contains("credential"))
        XCTAssertFalse(digest.contains("session-id"))
    }

    private func makeHarness(
        scheduler: MediaRecoveryTestScheduler = MediaRecoveryTestScheduler()
    ) -> MediaRecoveryHarness {
        let harness = MediaRecoveryHarness(scheduler: scheduler)
        harness.coordinator = ParsecMediaRecoveryCoordinator(
            scheduler: scheduler,
            softVideoDeadline: 3,
            hardMediaDeadline: 10,
            onAction: { harness.actions.append($0) }
        )
        return harness
    }

    private func snapshot(
        generation: UInt64,
        phase: ParsecSessionPhase = .waitingForMedia,
        intent: ParsecConnectIntent = .initial,
        media: ParsecMediaReadiness,
        disconnectReason: ParsecDisconnectReason? = nil
    ) -> ParsecSessionSnapshot {
        ParsecSessionSnapshot(
            generation: generation,
            sequence: generation,
            phase: phase,
            adapter: .fake,
            connectIntent: intent,
            transportStatus: .ok,
            media: media,
            disconnectReason: disconnectReason,
            lastFailure: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private final class MediaRecoveryHarness {
    let scheduler: MediaRecoveryTestScheduler
    var coordinator: ParsecMediaRecoveryCoordinator!
    var actions: [ParsecMediaRecoveryAction] = []

    init(scheduler: MediaRecoveryTestScheduler) {
        self.scheduler = scheduler
    }
}

private final class MediaRecoveryTestScheduler: BackgroundLifecycleScheduling {
    private let synchronousDelays: Set<TimeInterval>
    private(set) var tasks: [MediaRecoveryTestTask] = []

    init(synchronousDelays: Set<TimeInterval> = []) {
        self.synchronousDelays = synchronousDelays
    }

    var activeCount: Int { tasks.filter { !$0.isCancelled && !$0.didRun }.count }

    func activeTasks(delay: TimeInterval) -> Int {
        tasks.filter { $0.delay == delay && !$0.isCancelled && !$0.didRun }.count
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> BackgroundScheduledTask {
        let task = MediaRecoveryTestTask(delay: delay, action: action)
        tasks.append(task)
        if synchronousDelays.contains(delay) {
            task.run()
        }
        return task
    }

    func run(delay: TimeInterval) {
        tasks.first { $0.delay == delay && !$0.isCancelled && !$0.didRun }?.run()
    }

    func runAllIncludingCancelled() {
        tasks.forEach { $0.runIgnoringCancellation() }
    }
}

private final class MediaRecoveryTestTask: BackgroundScheduledTask {
    let delay: TimeInterval
    private let action: () -> Void
    private(set) var isCancelled = false
    private(set) var didRun = false

    init(delay: TimeInterval, action: @escaping () -> Void) {
        self.delay = delay
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func run() {
        guard !isCancelled, !didRun else { return }
        didRun = true
        action()
    }

    func runIgnoringCancellation() {
        guard !didRun else { return }
        didRun = true
        action()
    }
}
