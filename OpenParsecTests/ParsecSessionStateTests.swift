import XCTest
@testable import OpenParsec

final class ParsecSessionStateTests: XCTestCase {
    func testInitialSnapshotIsIdleAndUncorrelated() {
        let harness = makeHarness()

        XCTAssertEqual(harness.tracker.snapshot.phase, .idle)
        XCTAssertEqual(harness.tracker.snapshot.generation, 0)
        XCTAssertEqual(harness.tracker.snapshot.sequence, 0)
        XCTAssertEqual(harness.tracker.snapshot.transportStatus, .notRunning)
        XCTAssertEqual(harness.tracker.snapshot.media, .notReady)
        XCTAssertNil(harness.tracker.snapshot.disconnectReason)
        XCTAssertNil(harness.tracker.snapshot.lastFailure)
    }

    func testConnectTransportAndMediaProduceOneCoherentSequence() {
        let harness = makeHarness()

        let connecting = harness.tracker.beginConnect(intent: .initial, adapter: .fake)
        let generation = connecting.generation
        let transportReady = harness.tracker.observeTransport(.ok, generation: generation)
        let videoReady = harness.tracker.observeMedia(
            ParsecMediaReadiness(video: true, audio: false),
            generation: generation
        )
        let interactive = harness.tracker.observeMedia(.ready, generation: generation)

        XCTAssertEqual(connecting.phase, .connecting)
        XCTAssertEqual(transportReady?.phase, .waitingForMedia)
        // Audio is optional: video alone is interactive.
        XCTAssertEqual(videoReady?.phase, .interactive)
        XCTAssertEqual(interactive?.phase, .interactive)
        XCTAssertEqual(interactive?.generation, 1)
        XCTAssertEqual(interactive?.sequence, 4)
        XCTAssertEqual(interactive?.transportStatus, .ok)
        XCTAssertEqual(interactive?.media, .ready)
        XCTAssertEqual(harness.logger.transitions.count, 4)
    }

    func testBackgroundAndForegroundRestoreDerivedInteractivePhase() {
        let harness = makeHarness()
        let generation = harness.tracker.beginConnect(intent: .initial, adapter: .fake).generation
        _ = harness.tracker.observeTransport(.ok, generation: generation)
        _ = harness.tracker.observeMedia(.ready, generation: generation)

        let background = harness.tracker.enterBackground(generation: generation)
        let foreground = harness.tracker.resumeForeground(generation: generation)

        XCTAssertEqual(background?.phase, .background)
        XCTAssertEqual(foreground?.phase, .interactive)
        XCTAssertEqual(foreground?.media, .ready)
        XCTAssertEqual(foreground?.sequence, 5)
    }

    func testBackgroundGraceIsDistinctFromGenericBackground() {
        let harness = makeHarness()
        let generation = harness.tracker.beginConnect(intent: .initial, adapter: .fake).generation
        _ = harness.tracker.observeTransport(.ok, generation: generation)
        _ = harness.tracker.observeMedia(.ready, generation: generation)
        _ = harness.tracker.enterBackground(generation: generation)

        let grace = harness.tracker.enterBackgroundGrace(generation: generation)

        XCTAssertEqual(grace?.phase, .backgroundGrace)
        XCTAssertEqual(grace?.media, .ready)
    }

    func testReconnectIncrementsGenerationAndRejectsStaleObservations() {
        let harness = makeHarness()
        let firstGeneration = harness.tracker.beginConnect(intent: .initial, adapter: .fake).generation
        _ = harness.tracker.disconnect(reason: .backgroundExpired, generation: firstGeneration)

        let reconnecting = harness.tracker.beginConnect(intent: .reconnect, adapter: .fake)
        let acceptedSequence = reconnecting.sequence
        let transitionCount = harness.logger.transitions.count
        let stale = harness.tracker.observeTransport(
            RemoteStatus(rawValue: -6023),
            generation: firstGeneration,
            stage: .connecting
        )

        XCTAssertEqual(reconnecting.generation, firstGeneration + 1)
        XCTAssertEqual(reconnecting.phase, .reconnecting)
        XCTAssertNil(stale)
        XCTAssertEqual(harness.tracker.snapshot.sequence, acceptedSequence)
        XCTAssertEqual(harness.tracker.snapshot.phase, .reconnecting)
        XCTAssertEqual(harness.logger.transitions.count, transitionCount)
        XCTAssertNil(harness.failureStore.failure)
    }

    func testTransportFailureIsTerminalAndPersistsSafeDiagnosticFields() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = makeHarness(now: { timestamp })
        let generation = harness.tracker.beginConnect(intent: .initial, adapter: .fake).generation

        let failed = harness.tracker.observeTransport(
            RemoteStatus(rawValue: -6023),
            generation: generation,
            stage: .connecting
        )

        XCTAssertEqual(failed?.phase, .failed)
        XCTAssertEqual(failed?.disconnectReason, .transportFailure)
        XCTAssertEqual(failed?.lastFailure?.rawCode, -6023)
        XCTAssertEqual(failed?.lastFailure?.stage, .connecting)
        XCTAssertEqual(failed?.lastFailure?.generation, generation)
        XCTAssertEqual(failed?.lastFailure?.timestamp, timestamp)
        XCTAssertEqual(harness.failureStore.failure, failed?.lastFailure)

        let recreated = ParsecSessionTracker(
            failureStore: harness.failureStore,
            logger: harness.logger,
            now: { timestamp }
        )
        XCTAssertEqual(recreated.snapshot.phase, .idle)
        XCTAssertEqual(recreated.snapshot.lastFailure, failed?.lastFailure)
    }

    func testDisconnectRequiresAnExplicitReason() {
        let harness = makeHarness()
        let generation = harness.tracker.beginConnect(intent: .initial, adapter: .fake).generation

        let disconnected = harness.tracker.disconnect(reason: .user, generation: generation)

        XCTAssertEqual(disconnected?.phase, .disconnected)
        XCTAssertEqual(disconnected?.disconnectReason, .user)
        XCTAssertEqual(disconnected?.transportStatus, .notRunning)
        XCTAssertEqual(disconnected?.media, .notReady)
    }

    func testDuplicateObservationsDoNotAdvanceSequenceOrEraseReconnectIntent() {
        let harness = makeHarness()
        let generation = harness.tracker.beginConnect(intent: .reconnect, adapter: .real).generation
        let sequence = harness.tracker.snapshot.sequence
        let logCount = harness.logger.transitions.count

        let transport = harness.tracker.observeTransport(.connecting, generation: generation)
        let media = harness.tracker.observeMedia(.notReady, generation: generation)

        XCTAssertNil(transport)
        XCTAssertNil(media)
        XCTAssertEqual(harness.tracker.snapshot.sequence, sequence)
        XCTAssertEqual(harness.tracker.snapshot.phase, .reconnecting)
        XCTAssertEqual(harness.tracker.snapshot.connectIntent, .reconnect)
        XCTAssertEqual(harness.tracker.snapshot.adapter, .real)
        XCTAssertEqual(harness.logger.transitions.count, logCount)
    }

    func testInvalidNoOpTransitionsDoNotAdvanceSequenceOrEmitLogs() {
        let harness = makeHarness()

        XCTAssertNil(harness.tracker.enterBackground(generation: 0))
        XCTAssertNil(harness.tracker.enterBackgroundGrace(generation: 0))
        XCTAssertNil(harness.tracker.disconnect(reason: .user, generation: 0))
        XCTAssertEqual(harness.tracker.snapshot.sequence, 0)
        XCTAssertTrue(harness.logger.transitions.isEmpty)

        let generation = harness.tracker.beginConnect(intent: .initial, adapter: .fake).generation
        _ = harness.tracker.disconnect(reason: .user, generation: generation)
        let sequence = harness.tracker.snapshot.sequence
        let logCount = harness.logger.transitions.count

        XCTAssertNil(harness.tracker.disconnect(reason: .user, generation: generation))
        XCTAssertEqual(harness.tracker.snapshot.sequence, sequence)
        XCTAssertEqual(harness.logger.transitions.count, logCount)
    }

    func testUserDefaultsFailureStoreRoundTripsOnlySafeFields() throws {
        let suiteName = "ParsecSessionStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "last-failure"
        let store = UserDefaultsParsecFailureStore(defaults: defaults, key: key)
        let failure = ParsecSessionFailure(
            rawCode: -6023,
            stage: .connecting,
            adapter: .real,
            generation: 4,
            sequence: 12,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        store.saveLastFailure(failure)

        XCTAssertEqual(store.loadLastFailure(), failure)
        let data = try XCTUnwrap(defaults.data(forKey: key))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            Set(["rawCode", "stage", "adapter", "generation", "sequence", "timestamp"])
        )
    }

    private func makeHarness(
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 123) }
    ) -> Harness {
        let failureStore = InMemoryFailureStore()
        let logger = CapturingTransitionLogger()
        let tracker = ParsecSessionTracker(
            failureStore: failureStore,
            logger: logger,
            now: now
        )
        return Harness(tracker: tracker, failureStore: failureStore, logger: logger)
    }
}

private struct Harness {
    let tracker: ParsecSessionTracker
    let failureStore: InMemoryFailureStore
    let logger: CapturingTransitionLogger
}

private final class InMemoryFailureStore: ParsecFailurePersisting {
    var failure: ParsecSessionFailure?

    func loadLastFailure() -> ParsecSessionFailure? {
        failure
    }

    func saveLastFailure(_ failure: ParsecSessionFailure) {
        self.failure = failure
    }
}

private final class CapturingTransitionLogger: ParsecSessionTransitionLogging {
    private(set) var transitions: [ParsecSessionTransition] = []

    func log(_ transition: ParsecSessionTransition) {
        transitions.append(transition)
    }
}
