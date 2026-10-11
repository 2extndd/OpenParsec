import XCTest
@testable import OpenParsec

#if targetEnvironment(simulator)
final class FakeParsecServiceTests: XCTestCase {
    func testInitializeSelectsFakeAdapterOnSimulator() {
        CParsec.initialize(arguments: ["OpenParsec", "--fake-scenario=success"])

        XCTAssertEqual(CParsec.adapterKind, .fake)
        XCTAssertTrue(CParsec.parsecImpl is FakeParsecService)
    }

    func testCParsecOwnsFakeAdapterConnectionLifecycleNotifications() {
        ParsecBackgroundManager.shared.disableAutoReconnect()
        _ = CParsec.disconnect(reason: .user)
        CParsec.parsecImpl = FakeParsecService(scenario: .success)

        let status = CParsec.connect("peer-lifecycle")
        let generation = CParsec.sessionSnapshot.generation

        XCTAssertEqual(status, .connecting)
        XCTAssertTrue(ParsecBackgroundManager.shared.hasActiveConnection)

        XCTAssertTrue(CParsec.disconnect(reason: .user, generation: generation))
        XCTAssertFalse(ParsecBackgroundManager.shared.hasActiveConnection)
        XCTAssertEqual(ParsecBackgroundManager.shared.recoveryStateName, "idle")
    }

    func testDuplicateFacadeConnectDoesNotStartSecondAdapterGeneration() {
        ParsecBackgroundManager.shared.disableAutoReconnect()
        _ = CParsec.disconnect(reason: .user)
        let service = FakeParsecService(scenario: .success)
        CParsec.parsecImpl = service

        XCTAssertEqual(CParsec.connect("peer-duplicate"), .connecting)
        let generation = CParsec.sessionSnapshot.generation
        XCTAssertEqual(CParsec.connect("peer-duplicate"), .connecting)

        XCTAssertEqual(CParsec.sessionSnapshot.generation, generation)
        XCTAssertEqual(service.events.filter { $0 == .connectRequested }.count, 1)

        XCTAssertTrue(CParsec.disconnect(reason: .user, generation: generation))
    }

    func testInitializeCannotReplaceLiveAdapter() {
        ParsecBackgroundManager.shared.disableAutoReconnect()
        _ = CParsec.disconnect(reason: .user)
        let service = FakeParsecService(scenario: .success)
        CParsec.parsecImpl = service

        XCTAssertEqual(CParsec.connect("peer-live-adapter"), .connecting)
        let generation = CParsec.sessionSnapshot.generation
        CParsec.initialize(arguments: ["OpenParsec", "--fake-scenario=timeout"])

        XCTAssertTrue(CParsec.parsecImpl as? FakeParsecService === service)
        XCTAssertTrue(CParsec.disconnect(reason: .user, generation: generation))
    }

    func testBackgroundDuringAdapterConnectSeesOwnedConnectionAndOpensGrace() {
        ParsecBackgroundManager.shared.disableAutoReconnect()
        _ = CParsec.disconnect(reason: .user)
        let service = FakeParsecService(scenario: .success)
        var observedOwnedConnection = false
        service.connectHook = {
            observedOwnedConnection = ParsecBackgroundManager.shared.hasActiveConnection
            ParsecBackgroundManager.shared.sceneDidEnterBackground(pipProtected: false)
        }
        CParsec.parsecImpl = service

        let status = CParsec.connect("peer-connect-race")
        let generation = CParsec.sessionSnapshot.generation

        XCTAssertEqual(status, .connecting)
        XCTAssertTrue(observedOwnedConnection)
        XCTAssertEqual(ParsecBackgroundManager.shared.recoveryStateName, "grace")
        XCTAssertEqual(CParsec.sessionSnapshot.phase, .backgroundGrace)

        XCTAssertTrue(CParsec.disconnect(reason: .user, generation: generation))
        XCTAssertEqual(ParsecBackgroundManager.shared.recoveryStateName, "idle")
    }

    func testSuccessRequiresFreshRenderBeforeVideoIsReady() {
        let service = FakeParsecService(scenario: .success)

        XCTAssertEqual(service.connect("peer-1"), .connecting)
        XCTAssertEqual(service.getStatus(), .ok)
        XCTAssertEqual(
            service.mediaEvidence,
            ParsecMediaEvidence(
                readiness: ParsecMediaReadiness(video: false, audio: true),
                videoStatus: nil,
                audioStatus: .ok
            )
        )

        XCTAssertEqual(service.renderGLFrame(timeout: 16), .produced())
        XCTAssertEqual(service.mediaEvidence.readiness, .ready)
        XCTAssertEqual(
            service.events,
            [.connectRequested, .connecting, .audioReady, .firstFrame, .interactive]
        )
    }

    func testRendererFailureRetainsStatusWithoutClaimingFirstFrame() {
        let service = FakeParsecService(scenario: .rendererFailure)
        _ = service.connect("peer-render-failure")
        XCTAssertEqual(service.getStatus(), .ok)

        let result = service.renderGLFrame(timeout: 16)

        XCTAssertEqual(result, .noFrame(status: RemoteStatus(rawValue: -7001)))
        XCTAssertFalse(service.mediaEvidence.readiness.video)
        XCTAssertEqual(service.mediaEvidence.videoStatus?.rawValue, -7001)
        XCTAssertFalse(service.events.contains(.firstFrame))
        XCTAssertTrue(service.events.contains(.rendererFailed))
    }

    func testTimeoutScenarioRemainsDeterministic() {
        let service = FakeParsecService(scenario: .timeout)

        XCTAssertEqual(service.connect("peer-1"), .connecting)
        XCTAssertEqual(service.getStatus(), RemoteStatus(rawValue: -6023))
        XCTAssertEqual(service.events.suffix(1), [.timedOut])
    }

    func testBlackFrameAndAudioStallExposeDifferentReadiness() {
        let blackFrame = FakeParsecService(scenario: .blackFrame)
        _ = blackFrame.connect("peer-1")
        XCTAssertEqual(blackFrame.getStatus(), .ok)
        XCTAssertFalse(blackFrame.events.contains(.firstFrame))
        XCTAssertTrue(blackFrame.events.contains(.audioReady))

        let audioStall = FakeParsecService(scenario: .audioStall)
        _ = audioStall.connect("peer-1")
        XCTAssertEqual(audioStall.getStatus(), .ok)
        XCTAssertFalse(audioStall.events.contains(.firstFrame))
        XCTAssertFalse(audioStall.events.contains(.audioReady))
        XCTAssertEqual(audioStall.renderGLFrame(timeout: 16), .produced())
        XCTAssertTrue(audioStall.events.contains(.firstFrame))
    }

    func testReconnectScenarioSucceedsOnSecondConnect() {
        let service = FakeParsecService(scenario: .reconnect)

        XCTAssertEqual(service.connect("peer-1"), .connecting)
        XCTAssertEqual(service.getStatus(), RemoteStatus(rawValue: -6023))
        XCTAssertEqual(service.connect("peer-1"), .connecting)
        XCTAssertEqual(service.getStatus(), .ok)
        XCTAssertEqual(service.renderGLFrame(timeout: 16), .produced())
        XCTAssertEqual(service.events.suffix(4), [.reconnecting, .audioReady, .firstFrame, .interactive])
    }

    func testScenarioMediaReadinessMatchesDeterministicEvents() {
        let success = FakeParsecService(scenario: .success)
        _ = success.connect("peer-1")
        _ = success.getStatus()
        XCTAssertEqual(success.mediaReadiness, ParsecMediaReadiness(video: false, audio: true))
        _ = success.renderGLFrame(timeout: 16)
        XCTAssertEqual(success.mediaReadiness, .ready)

        let blackFrame = FakeParsecService(scenario: .blackFrame)
        _ = blackFrame.connect("peer-1")
        _ = blackFrame.getStatus()
        XCTAssertEqual(blackFrame.mediaReadiness, ParsecMediaReadiness(video: false, audio: true))

        let audioStall = FakeParsecService(scenario: .audioStall)
        _ = audioStall.connect("peer-1")
        _ = audioStall.getStatus()
        XCTAssertEqual(audioStall.mediaReadiness, .notReady)
        _ = audioStall.renderGLFrame(timeout: 16)
        XCTAssertEqual(audioStall.mediaReadiness, ParsecMediaReadiness(video: true, audio: false))

        let timeout = FakeParsecService(scenario: .timeout)
        _ = timeout.connect("peer-1")
        _ = timeout.getStatus()
        XCTAssertEqual(timeout.mediaReadiness, .notReady)
    }

    func testDisconnectWaitsForInFlightRenderFrame() {
        ParsecBackgroundManager.shared.disableAutoReconnect()
        _ = CParsec.disconnect(reason: .user)
        let service = FakeParsecService(scenario: .success)
        CParsec.parsecImpl = service

        XCTAssertEqual(CParsec.connect("peer-render-race"), .connecting)
        XCTAssertEqual(CParsec.getStatus(), .ok)
        let generation = CParsec.sessionSnapshot.generation

        let renderEntered = DispatchSemaphore(value: 0)
        let releaseRender = DispatchSemaphore(value: 0)
        let renderFinished = DispatchSemaphore(value: 0)
        let disconnectEntered = DispatchSemaphore(value: 0)
        let disconnectFinished = DispatchSemaphore(value: 0)

        service.renderFrameHook = {
            renderEntered.signal()
            _ = releaseRender.wait(timeout: .now() + 2)
        }
        service.disconnectHook = {
            disconnectEntered.signal()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = CParsec.renderGLFrame(timeout: 1)
            renderFinished.signal()
        }
        XCTAssertEqual(renderEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = CParsec.disconnect(reason: .transportFailure, generation: generation)
            disconnectFinished.signal()
        }
        XCTAssertEqual(disconnectEntered.wait(timeout: .now() + 0.1), .timedOut)

        releaseRender.signal()
        XCTAssertEqual(renderFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(disconnectEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(disconnectFinished.wait(timeout: .now() + 1), .success)
    }
}
#endif
