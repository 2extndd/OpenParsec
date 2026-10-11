import Foundation
import OSLog

extension Notification.Name {
    static let parsecSessionSnapshotDidChange = Notification.Name(
        "OpenParsecSessionSnapshotDidChange"
    )
    static let parsecDisplayOutputDidConfirm = Notification.Name(
        "OpenParsecDisplayOutputDidConfirm"
    )
}

enum ParsecSessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case connecting
    case waitingForMedia = "waiting-for-media"
    case waitingForFirstFrame = "waiting-for-first-frame"
    case interactive
    case background
    case backgroundGrace = "background-grace"
    case reconnecting
    case failed
    case disconnected
}

enum ParsecConnectIntent: String, Codable, Equatable, Sendable {
    case initial
    case reconnect
    case reconfigure
}

enum ParsecDisconnectReason: String, Codable, Equatable, Sendable {
    case user
    case backgroundExpired = "background-expired"
    case transportFailure = "transport-failure"
    case reconfigure
    case adapterDestroyed = "adapter-destroyed"
}

enum ParsecFailureStage: String, Codable, Equatable, Sendable {
    case connecting
    case transport
    case video
    case audio
    case reconnecting
}

struct ParsecMediaReadiness: Codable, Equatable, Sendable {
    var video: Bool
    var audio: Bool

    static let notReady = ParsecMediaReadiness(video: false, audio: false)
    static let ready = ParsecMediaReadiness(video: true, audio: true)
}

struct ParsecSessionFailure: Codable, Equatable, Sendable {
    let rawCode: Int32
    let stage: ParsecFailureStage
    let adapter: ParsecAdapterKind
    let generation: UInt64
    let sequence: UInt64
    let timestamp: Date
}

struct ParsecSessionSnapshot: Equatable, Sendable {
    let generation: UInt64
    let sequence: UInt64
    let phase: ParsecSessionPhase
    let adapter: ParsecAdapterKind
    let connectIntent: ParsecConnectIntent?
    let transportStatus: RemoteStatus
    let media: ParsecMediaReadiness
    let disconnectReason: ParsecDisconnectReason?
    let lastFailure: ParsecSessionFailure?
    let updatedAt: Date

    var digest: String {
        let reason = disconnectReason?.rawValue ?? "none"
        let failure = lastFailure.map { "\($0.rawCode)@\($0.stage.rawValue)" } ?? "none"
        return "phase=\(phase.rawValue) generation=\(generation) sequence=\(sequence) status=\(transportStatus.rawValue) video=\(media.video) audio=\(media.audio) adapter=\(adapter.rawValue) reason=\(reason) lastFailure=\(failure)"
    }
}

struct ParsecSessionTransition: Equatable, Sendable {
    let event: String
    let previousPhase: ParsecSessionPhase
    let snapshot: ParsecSessionSnapshot
}

protocol ParsecFailurePersisting: AnyObject {
    func loadLastFailure() -> ParsecSessionFailure?
    func saveLastFailure(_ failure: ParsecSessionFailure)
}

final class UserDefaultsParsecFailureStore: ParsecFailurePersisting {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "openparsec.session.last-failure.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadLastFailure() -> ParsecSessionFailure? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(ParsecSessionFailure.self, from: data)
    }

    func saveLastFailure(_ failure: ParsecSessionFailure) {
        guard let data = try? encoder.encode(failure) else { return }
        defaults.set(data, forKey: key)
    }
}

protocol ParsecSessionTransitionLogging: AnyObject {
    func log(_ transition: ParsecSessionTransition)
}

final class OSLogParsecSessionTransitionLogger: ParsecSessionTransitionLogging {
    private let logger = Logger(subsystem: "com.openparsec.client", category: "session")

    func log(_ transition: ParsecSessionTransition) {
        let snapshot = transition.snapshot
        let reason = snapshot.disconnectReason?.rawValue ?? "none"
        let failure = snapshot.lastFailure.map { "\($0.rawCode)@\($0.stage.rawValue)" } ?? "none"
        logger.info(
            "event=session_transition name=\(transition.event, privacy: .public) generation=\(snapshot.generation, privacy: .public) sequence=\(snapshot.sequence, privacy: .public) from=\(transition.previousPhase.rawValue, privacy: .public) to=\(snapshot.phase.rawValue, privacy: .public) status=\(snapshot.transportStatus.rawValue, privacy: .public) video=\(snapshot.media.video, privacy: .public) audio=\(snapshot.media.audio, privacy: .public) adapter=\(snapshot.adapter.rawValue, privacy: .public) reason=\(reason, privacy: .public) lastFailure=\(failure, privacy: .public)"
        )
    }
}

final class ParsecSessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let failureStore: ParsecFailurePersisting
    private let transitionLogger: ParsecSessionTransitionLogging
    private let now: () -> Date
    private var current: ParsecSessionSnapshot

    init(
        failureStore: ParsecFailurePersisting = UserDefaultsParsecFailureStore(),
        logger: ParsecSessionTransitionLogging = OSLogParsecSessionTransitionLogger(),
        now: @escaping () -> Date = Date.init
    ) {
        self.failureStore = failureStore
        self.transitionLogger = logger
        self.now = now
        current = ParsecSessionSnapshot(
            generation: 0,
            sequence: 0,
            phase: .idle,
            adapter: .uninitialized,
            connectIntent: nil,
            transportStatus: .notRunning,
            media: .notReady,
            disconnectReason: nil,
            lastFailure: failureStore.loadLastFailure(),
            updatedAt: now()
        )
    }

    var snapshot: ParsecSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    @discardableResult
    func beginConnect(intent: ParsecConnectIntent, adapter: ParsecAdapterKind) -> ParsecSessionSnapshot {
        let result = transition(event: "connect-requested") { previous, timestamp in
            ParsecSessionSnapshot(
                generation: previous.generation &+ 1,
                sequence: previous.sequence &+ 1,
                phase: intent == .reconnect ? .reconnecting : .connecting,
                adapter: adapter,
                connectIntent: intent,
                transportStatus: .connecting,
                media: .notReady,
                disconnectReason: nil,
                lastFailure: previous.lastFailure,
                updatedAt: timestamp
            )
        }
        return result.snapshot
    }

    @discardableResult
    func observeTransport(
        _ status: RemoteStatus,
        generation: UInt64,
        stage: ParsecFailureStage = .transport
    ) -> ParsecSessionSnapshot? {
        transitionIfCurrent(event: "transport-status", generation: generation) { previous, timestamp in
            if status == previous.transportStatus, status.isFailure, previous.phase == .failed {
                return nil
            }
            let nextSequence = previous.sequence &+ 1
            if status.isFailure {
                let failure = ParsecSessionFailure(
                    rawCode: status.rawValue,
                    stage: stage,
                    adapter: previous.adapter,
                    generation: previous.generation,
                    sequence: nextSequence,
                    timestamp: timestamp
                )
                return ParsecSessionSnapshot(
                    generation: previous.generation,
                    sequence: nextSequence,
                    phase: .failed,
                    adapter: previous.adapter,
                    connectIntent: previous.connectIntent,
                    transportStatus: status,
                    media: previous.media,
                    disconnectReason: .transportFailure,
                    lastFailure: failure,
                    updatedAt: timestamp
                )
            }

            let phase: ParsecSessionPhase
            if [.background, .backgroundGrace].contains(previous.phase) {
                phase = previous.phase
            } else if status.isConnecting {
                phase = previous.connectIntent == .reconnect ? .reconnecting : .connecting
            } else if status.isOK {
                phase = Self.activePhase(for: previous.media)
            } else {
                phase = previous.phase
            }

            guard status != previous.transportStatus || phase != previous.phase else { return nil }
            return ParsecSessionSnapshot(
                generation: previous.generation,
                sequence: nextSequence,
                phase: phase,
                adapter: previous.adapter,
                connectIntent: previous.connectIntent,
                transportStatus: status,
                media: previous.media,
                disconnectReason: nil,
                lastFailure: previous.lastFailure,
                updatedAt: timestamp
            )
        }
    }

    @discardableResult
    func observeMedia(
        _ media: ParsecMediaReadiness,
        generation: UInt64
    ) -> ParsecSessionSnapshot? {
        transitionIfCurrent(event: "media-readiness", generation: generation) { previous, timestamp in
            let phase = [.background, .backgroundGrace].contains(previous.phase)
                ? previous.phase
                : (previous.transportStatus.isOK ? Self.activePhase(for: media) : previous.phase)
            guard media != previous.media || phase != previous.phase else { return nil }
            return ParsecSessionSnapshot(
                generation: previous.generation,
                sequence: previous.sequence &+ 1,
                phase: phase,
                adapter: previous.adapter,
                connectIntent: previous.connectIntent,
                transportStatus: previous.transportStatus,
                media: media,
                disconnectReason: previous.disconnectReason,
                lastFailure: previous.lastFailure,
                updatedAt: timestamp
            )
        }
    }

    @discardableResult
    func enterBackground(generation: UInt64) -> ParsecSessionSnapshot? {
        transitionIfCurrent(event: "background-entered", generation: generation) { previous, timestamp in
            guard ![.idle, .background, .backgroundGrace, .disconnected, .failed].contains(previous.phase) else { return nil }
            return ParsecSessionSnapshot(
                generation: previous.generation,
                sequence: previous.sequence &+ 1,
                phase: .background,
                adapter: previous.adapter,
                connectIntent: previous.connectIntent,
                transportStatus: previous.transportStatus,
                media: previous.media,
                disconnectReason: nil,
                lastFailure: previous.lastFailure,
                updatedAt: timestamp
            )
        }
    }

    @discardableResult
    func enterBackgroundGrace(generation: UInt64) -> ParsecSessionSnapshot? {
        transitionIfCurrent(event: "background-grace-started", generation: generation) { previous, timestamp in
            guard ![.idle, .backgroundGrace, .disconnected, .failed].contains(previous.phase) else { return nil }
            return ParsecSessionSnapshot(
                generation: previous.generation,
                sequence: previous.sequence &+ 1,
                phase: .backgroundGrace,
                adapter: previous.adapter,
                connectIntent: previous.connectIntent,
                transportStatus: previous.transportStatus,
                media: previous.media,
                disconnectReason: nil,
                lastFailure: previous.lastFailure,
                updatedAt: timestamp
            )
        }
    }

    @discardableResult
    func resumeForeground(generation: UInt64) -> ParsecSessionSnapshot? {
        transitionIfCurrent(event: "foreground-resumed", generation: generation) { previous, timestamp in
            guard [.background, .backgroundGrace].contains(previous.phase) else { return nil }
            let phase: ParsecSessionPhase
            if previous.transportStatus.isOK {
                phase = Self.activePhase(for: previous.media)
            } else if previous.transportStatus.isConnecting {
                phase = previous.connectIntent == .reconnect ? .reconnecting : .connecting
            } else {
                phase = previous.phase
            }
            return ParsecSessionSnapshot(
                generation: previous.generation,
                sequence: previous.sequence &+ 1,
                phase: phase,
                adapter: previous.adapter,
                connectIntent: previous.connectIntent,
                transportStatus: previous.transportStatus,
                media: previous.media,
                disconnectReason: previous.disconnectReason,
                lastFailure: previous.lastFailure,
                updatedAt: timestamp
            )
        }
    }

    @discardableResult
    func disconnect(
        reason: ParsecDisconnectReason,
        generation: UInt64
    ) -> ParsecSessionSnapshot? {
        transitionIfCurrent(event: "disconnected", generation: generation) { previous, timestamp in
            guard ![.idle, .disconnected].contains(previous.phase) else { return nil }
            return ParsecSessionSnapshot(
                generation: previous.generation,
                sequence: previous.sequence &+ 1,
                phase: .disconnected,
                adapter: previous.adapter,
                connectIntent: previous.connectIntent,
                transportStatus: .notRunning,
                media: .notReady,
                disconnectReason: reason,
                lastFailure: previous.lastFailure,
                updatedAt: timestamp
            )
        }
    }

    private static func activePhase(for media: ParsecMediaReadiness) -> ParsecSessionPhase {
        // Audio is optional: an idle or headless host may never send an audio
        // packet, so the first video frame alone makes the session interactive.
        switch (media.video, media.audio) {
        case (true, _):
            return .interactive
        case (false, true):
            return .waitingForFirstFrame
        case (false, false):
            return .waitingForMedia
        }
    }

    private func transition(
        event: String,
        mutation: (ParsecSessionSnapshot, Date) -> ParsecSessionSnapshot
    ) -> ParsecSessionTransition {
        lock.lock()
        let previous = current
        let next = mutation(previous, now())
        current = next
        lock.unlock()

        if next.lastFailure != previous.lastFailure, let failure = next.lastFailure {
            failureStore.saveLastFailure(failure)
        }
        let transition = ParsecSessionTransition(
            event: event,
            previousPhase: previous.phase,
            snapshot: next
        )
        publish(transition)
        return transition
    }

    private func publish(_ transition: ParsecSessionTransition) {
        transitionLogger.log(transition)
        NotificationCenter.default.post(
            name: .parsecSessionSnapshotDidChange,
            object: transition.snapshot
        )
    }

    private func transitionIfCurrent(
        event: String,
        generation: UInt64,
        mutation: (ParsecSessionSnapshot, Date) -> ParsecSessionSnapshot?
    ) -> ParsecSessionSnapshot? {
        lock.lock()
        guard generation == current.generation else {
            lock.unlock()
            return nil
        }
        let previous = current
        guard let next = mutation(previous, now()) else {
            lock.unlock()
            return nil
        }
        current = next
        lock.unlock()

        if next.lastFailure != previous.lastFailure, let failure = next.lastFailure {
            failureStore.saveLastFailure(failure)
        }
        let transition = ParsecSessionTransition(
            event: event,
            previousPhase: previous.phase,
            snapshot: next
        )
        publish(transition)
        return next
    }
}
