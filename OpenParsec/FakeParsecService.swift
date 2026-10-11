#if targetEnvironment(simulator)
import CoreGraphics
import Foundation

enum FakeParsecScenario: String, Equatable, Sendable {
    case success
    case timeout
    case blackFrame
    case audioStall
    case rendererFailure
    case reconnect
    case mediaRecovery
    case reconnectExhaustion
    case transportRecovery
    case transportReconnectExhaustion
    case transportReconnectPending

    static func resolve(arguments: [String]) -> FakeParsecScenario {
        let prefix = "--fake-scenario="
        guard
            let value = arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count),
            let scenario = FakeParsecScenario(rawValue: String(value))
        else {
            return .success
        }
        return scenario
    }
}

enum FakeParsecEvent: String, Equatable, Sendable {
    case connectRequested
    case connecting
    case reconnecting
    case firstFrame
    case audioReady
    case interactive
    case timedOut
    case transportFailed
    case rendererFailed
    case disconnected
}

final class FakeParsecService: ParsecService {
    let adapterKind: ParsecAdapterKind = .fake
    var clientWidth: Float = 1024
    var clientHeight: Float = 768
    var hostWidth: Float = 1920
    var hostHeight: Float = 1080
    var mouseInfo = MouseInfo()
    var hostOSValue = -1
    private(set) var mediaEvidence = ParsecMediaEvidence.initial
    var mediaReadiness: ParsecMediaReadiness { mediaEvidence.readiness }

    let scenario: FakeParsecScenario
    private(set) var events: [FakeParsecEvent] = []
    private(set) var connectedPeerID: String?
    private(set) var keyboardEventCount = 0
    private(set) var gamepadButtonEvents: [String] = []
    private(set) var gamepadAxisEvents: [String] = []
    private(set) var gamepadUnplugCount = 0
    private var status: RemoteStatus = .notRunning
    private var connectionCount = 0
    private var activeStatusPollCount = 0
#if DEBUG
    var connectHook: (() -> Void)?
    var renderFrameHook: (() -> Void)?
    var disconnectHook: (() -> Void)?
#endif

    convenience init(arguments: [String]) {
        self.init(scenario: FakeParsecScenario.resolve(arguments: arguments))
    }

    init(scenario: FakeParsecScenario) {
        self.scenario = scenario
    }

    func connect(_ peerID: String) -> RemoteStatus {
        connectionCount += 1
        activeStatusPollCount = 0
        connectedPeerID = peerID
        mediaEvidence = .initial
        events.append(.connectRequested)
        events.append(connectionCount > 1 ? .reconnecting : .connecting)
        status = .connecting
#if DEBUG
        connectHook?()
#endif
        return status
    }

    func disconnect() {
#if DEBUG
        disconnectHook?()
#endif
        status = .notRunning
        mediaEvidence = .initial
        connectedPeerID = nil
        events.append(.disconnected)
    }

    func getStatus() -> RemoteStatus {
        advanceConnectionIfNeeded()
        advanceActiveTransportIfNeeded()
        return status
    }

    func getStatusEx() -> RemoteClientStatus {
        advanceConnectionIfNeeded()
        advanceActiveTransportIfNeeded()
        return RemoteClientStatus(
            status: status,
            metrics: RemoteClientMetrics(
                decodeLatency: 1.25,
                encodeLatency: 2.5,
                networkLatency: 3.75,
                bitrate: 20
            ),
            decoder: RemoteDecoderStatus(
                name: "OpenParsec Fake",
                width: UInt32(hostWidth),
                height: UInt32(hostHeight),
                usesH265: false,
                usesColor444: false
            )
        )
    }

    private func advanceConnectionIfNeeded() {
        guard status == .connecting else { return }

        switch scenario {
        case .success, .blackFrame, .rendererFailure, .mediaRecovery:
            events.append(.audioReady)
            mediaEvidence.audioStatus = .ok
            mediaEvidence.readiness.audio = true
            status = .ok
        case .timeout:
            events.append(.timedOut)
            mediaEvidence = .initial
            status = RemoteStatus(rawValue: -6023)
        case .audioStall, .reconnectExhaustion:
            status = .ok
        case .reconnect:
            if connectionCount == 1 {
                events.append(.timedOut)
                mediaEvidence = .initial
                status = RemoteStatus(rawValue: -6023)
            } else {
                events.append(.audioReady)
                mediaEvidence.audioStatus = .ok
                mediaEvidence.readiness.audio = true
                status = .ok
            }
        case .transportRecovery, .transportReconnectExhaustion, .transportReconnectPending:
            if connectionCount == 1 {
                events.append(.audioReady)
                mediaEvidence.audioStatus = .ok
                mediaEvidence.readiness.audio = true
                status = .ok
            } else if scenario == .transportReconnectExhaustion {
                events.append(.timedOut)
                mediaEvidence = .initial
                status = RemoteStatus(rawValue: -6023)
            } else if scenario == .transportRecovery {
                events.append(.audioReady)
                mediaEvidence.audioStatus = .ok
                mediaEvidence.readiness.audio = true
                status = .ok
            }
        }
    }

    private func advanceActiveTransportIfNeeded() {
        guard connectionCount == 1, status == .ok else { return }
        guard scenario == .transportRecovery
                || scenario == .transportReconnectExhaustion
                || scenario == .transportReconnectPending else {
            return
        }
        activeStatusPollCount += 1
        guard activeStatusPollCount >= 3 else { return }
        events.append(.transportFailed)
        status = RemoteStatus(rawValue: -6023)
    }

    func setFrame(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) {
        clientWidth = Float(width)
        clientHeight = Float(height)
    }

    func renderGLFrame(timeout: UInt32) -> ParsecRenderFrameResult {
#if DEBUG
        renderFrameHook?()
#endif
        let result: ParsecRenderFrameResult
        switch scenario {
        case .blackFrame, .reconnectExhaustion:
            result = .noFrame(status: RemoteStatus(rawValue: 1))
        case .mediaRecovery where connectionCount == 1:
            result = .noFrame(status: RemoteStatus(rawValue: 1))
        case .rendererFailure:
            events.append(.rendererFailed)
            result = .noFrame(status: RemoteStatus(rawValue: -7001))
        case .timeout:
            result = .noFrame(status: .notRunning)
        case .success, .audioStall, .reconnect, .mediaRecovery,
             .transportRecovery, .transportReconnectExhaustion, .transportReconnectPending:
            if !mediaEvidence.readiness.video {
                events.append(.firstFrame)
            }
            mediaEvidence.readiness.video = true
            result = .produced()
            if mediaEvidence.readiness.audio,
               !events.contains(.interactive) {
                events.append(.interactive)
            }
        }
        mediaEvidence.videoStatus = result.status
        return result
    }
    func setMuted(_ muted: Bool) {}
    func applyConfig() {}
    func sendMouseMessage(_ button: RemoteMouseButton, _ x: Int32, _ y: Int32, _ pressed: Bool) {}
    func sendMouseClickMessage(_ button: RemoteMouseButton, _ pressed: Bool) {}
    func sendMouseDelta(_ dx: Int32, _ dy: Int32) {}
    func sendMousePosition(_ x: Int32, _ y: Int32) {}
    func sendKeyboardMessage(event: KeyBoardKeyEvent) {
        keyboardEventCount += 1
    }
    func sendVirtualKeyboardInput(text: String) {
        keyboardEventCount += 1
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
    func sendUserData(type: ParsecUserDataType, message: Data) {}
    func updateHostVideoConfig() {}
}
#endif
