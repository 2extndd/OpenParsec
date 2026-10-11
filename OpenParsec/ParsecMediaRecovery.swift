import Foundation
import OSLog

extension Notification.Name {
    static let parsecMediaRecoveryDidChange = Notification.Name(
        "OpenParsec.ParsecMediaRecoveryDidChange"
    )
    static let parsecMediaRecoveryActionRequested = Notification.Name(
        "OpenParsec.ParsecMediaRecoveryActionRequested"
    )
}

enum ParsecMediaRecoveryPhase: String, Equatable, Sendable {
    case idle
    case waiting
    case surfaceResumeRequested = "surface-resume-requested"
    case reconnectRequested = "reconnect-requested"
    case recovered
    case terminalFailure = "terminal-failure"
}

enum ParsecMissingMedia: String, Equatable, Sendable {
    case none
    case video
    case audio
    case videoAndAudio = "video-and-audio"
}

enum ParsecMediaRecoveryAction: Equatable, Sendable {
    case resumeVideoSurface(generation: UInt64)
    case reconnect(generation: UInt64)
    case terminalFailure(generation: UInt64, stage: ParsecFailureStage)
}

struct ParsecMediaRecoverySnapshot: Equatable, Sendable {
    let generation: UInt64
    let phase: ParsecMediaRecoveryPhase
    let missing: ParsecMissingMedia
    let reconnectUsed: Bool
    let deadlineToken: UInt64

    var digest: String {
        "phase=\(phase.rawValue) generation=\(generation) missing=\(missing.rawValue) reconnectUsed=\(reconnectUsed) deadline=\(deadlineToken)"
    }
}

protocol ParsecMediaRecoveryLogging: AnyObject {
    func record(_ snapshot: ParsecMediaRecoverySnapshot)
}

final class OSParsecMediaRecoveryLogger: ParsecMediaRecoveryLogging {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenParsec",
        category: "media-recovery"
    )

    func record(_ snapshot: ParsecMediaRecoverySnapshot) {
        logger.info("media recovery \(snapshot.digest, privacy: .public)")
    }
}

private final class MediaRecoveryDispatchTask: BackgroundScheduledTask {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

final class MainQueueMediaRecoveryScheduler: BackgroundLifecycleScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> BackgroundScheduledTask {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return MediaRecoveryDispatchTask(item: item)
    }
}

final class ParsecMediaRecoveryCoordinator {
    private struct DeadlineContext {
        let generation: UInt64
        let token: UInt64
        let needsVideoDeadline: Bool
    }

    private struct Tasks {
        let soft: BackgroundScheduledTask?
        let hard: BackgroundScheduledTask?
    }

    private let lock = NSLock()
    private let scheduler: BackgroundLifecycleScheduling
    private let softVideoDeadline: TimeInterval
    private let hardMediaDeadline: TimeInterval
    private let logger: ParsecMediaRecoveryLogging
    private let onAction: (ParsecMediaRecoveryAction) -> Void

    private var generation: UInt64 = 0
    private var phase: ParsecMediaRecoveryPhase = .idle
    private var media: ParsecMediaReadiness = .notReady
    private var reconnectUsed = false
    private var deadlineToken: UInt64 = 0
    private var softArmed = false
    private var hardArmed = false
    private var softTask: BackgroundScheduledTask?
    private var hardTask: BackgroundScheduledTask?
    private var lastPublishedSnapshot: ParsecMediaRecoverySnapshot?

    init(
        scheduler: BackgroundLifecycleScheduling,
        softVideoDeadline: TimeInterval = 3,
        hardMediaDeadline: TimeInterval = 10,
        logger: ParsecMediaRecoveryLogging = OSParsecMediaRecoveryLogger(),
        onAction: @escaping (ParsecMediaRecoveryAction) -> Void
    ) {
        self.scheduler = scheduler
        self.softVideoDeadline = softVideoDeadline
        self.hardMediaDeadline = hardMediaDeadline
        self.logger = logger
        self.onAction = onAction
    }

    var snapshot: ParsecMediaRecoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    func observe(
        _ session: ParsecSessionSnapshot,
        evidence: ParsecMediaEvidence? = nil
    ) {
        var tasksToCancel = Tasks(soft: nil, hard: nil)
        var deadlineContext: DeadlineContext?
        var shouldPublish = false

        lock.lock()
        let generationChanged = session.generation != generation
        if generationChanged {
            let carriesReconnectBudget = phase == .reconnectRequested
                && session.connectIntent == .reconnect
                && session.generation > generation
            tasksToCancel = detachTasksLocked(invalidateToken: true)
            generation = session.generation
            reconnectUsed = carriesReconnectBudget
            phase = .idle
        }

        media = session.media
        if evidence?.videoStatus?.isFailure == true {
            media.video = false
        }
        if evidence?.audioStatus?.isFailure == true {
            media.audio = false
        }

        if preservesReconnectHandoff(session) || preservesTerminalFailure(session) {
            shouldPublish = generationChanged
        } else if shouldSuspendRecovery(for: session.phase) {
            let detached = detachTasksLocked(invalidateToken: true)
            tasksToCancel = merge(tasksToCancel, detached)
            phase = .idle
            reconnectUsed = false
            shouldPublish = true
        } else if media.video {
            let detached = detachTasksLocked(invalidateToken: true)
            tasksToCancel = merge(tasksToCancel, detached)
            phase = .recovered
            shouldPublish = true
        } else if session.transportStatus == .ok,
                  !hardArmed,
                  phase != .reconnectRequested,
                  phase != .terminalFailure {
            deadlineToken &+= 1
            softArmed = !media.video
            hardArmed = true
            phase = .waiting
            deadlineContext = DeadlineContext(
                generation: generation,
                token: deadlineToken,
                needsVideoDeadline: softArmed
            )
            shouldPublish = true
        } else if generationChanged {
            shouldPublish = true
        }
        lock.unlock()

        cancel(tasksToCancel)
        if shouldPublish {
            publishIfChanged()
        }
        if let deadlineContext {
            installDeadlines(deadlineContext)
        }
    }

    func cancel() {
        lock.lock()
        let tasks = detachTasksLocked(invalidateToken: true)
        phase = .idle
        reconnectUsed = false
        lock.unlock()

        cancel(tasks)
        publishIfChanged()
    }

    private func installDeadlines(_ context: DeadlineContext) {
        if context.needsVideoDeadline {
            let scheduled = scheduler.schedule(after: softVideoDeadline) { [weak self] in
                self?.fireSoftDeadline(
                    generation: context.generation,
                    token: context.token
                )
            }
            lock.lock()
            let acceptsTask = generation == context.generation
                && deadlineToken == context.token
                && softArmed
            if acceptsTask {
                softTask = scheduled
            }
            lock.unlock()
            if !acceptsTask {
                scheduled.cancel()
            }
        }

        let scheduled = scheduler.schedule(after: hardMediaDeadline) { [weak self] in
            self?.fireHardDeadline(
                generation: context.generation,
                token: context.token
            )
        }
        lock.lock()
        let acceptsTask = generation == context.generation
            && deadlineToken == context.token
            && hardArmed
        if acceptsTask {
            hardTask = scheduled
        }
        lock.unlock()
        if !acceptsTask {
            scheduled.cancel()
        }
    }

    private func fireSoftDeadline(generation: UInt64, token: UInt64) {
        var action: ParsecMediaRecoveryAction?
        lock.lock()
        if self.generation == generation,
           deadlineToken == token,
           softArmed,
           !media.video,
           phase == .waiting {
            softArmed = false
            softTask = nil
            phase = .surfaceResumeRequested
            action = .resumeVideoSurface(generation: generation)
        }
        lock.unlock()

        guard let action else { return }
        publishIfChanged()
        onAction(action)
    }

    private func fireHardDeadline(generation: UInt64, token: UInt64) {
        var action: ParsecMediaRecoveryAction?
        var softToCancel: BackgroundScheduledTask?
        lock.lock()
        if self.generation == generation,
           deadlineToken == token,
           hardArmed,
           !media.video,
           phase != .reconnectRequested,
           phase != .terminalFailure {
            hardArmed = false
            hardTask = nil
            softArmed = false
            softToCancel = softTask
            softTask = nil

            if reconnectUsed {
                phase = .terminalFailure
                action = .terminalFailure(
                    generation: generation,
                    stage: .video
                )
            } else {
                reconnectUsed = true
                phase = .reconnectRequested
                action = .reconnect(generation: generation)
            }
        }
        lock.unlock()

        softToCancel?.cancel()
        guard let action else { return }
        publishIfChanged()
        onAction(action)
    }

    private func preservesReconnectHandoff(_ session: ParsecSessionSnapshot) -> Bool {
        guard phase == .reconnectRequested,
              session.generation == generation else { return false }
        switch session.phase {
        case .failed:
            return true
        case .disconnected:
            return session.disconnectReason == .transportFailure
                || session.disconnectReason == .backgroundExpired
        default:
            return false
        }
    }

    private func preservesTerminalFailure(_ session: ParsecSessionSnapshot) -> Bool {
        phase == .terminalFailure
            && session.generation == generation
            && session.phase == .failed
    }

    private func shouldSuspendRecovery(for phase: ParsecSessionPhase) -> Bool {
        switch phase {
        case .idle, .background, .backgroundGrace, .failed, .disconnected:
            return true
        case .connecting, .waitingForMedia, .waitingForFirstFrame,
             .interactive, .reconnecting:
            return false
        }
    }

    private func detachTasksLocked(invalidateToken: Bool) -> Tasks {
        let tasks = Tasks(soft: softTask, hard: hardTask)
        softTask = nil
        hardTask = nil
        softArmed = false
        hardArmed = false
        if invalidateToken {
            deadlineToken &+= 1
        }
        return tasks
    }

    private func merge(_ lhs: Tasks, _ rhs: Tasks) -> Tasks {
        Tasks(soft: rhs.soft ?? lhs.soft, hard: rhs.hard ?? lhs.hard)
    }

    private func cancel(_ tasks: Tasks) {
        tasks.soft?.cancel()
        tasks.hard?.cancel()
    }

    private func snapshotLocked() -> ParsecMediaRecoverySnapshot {
        ParsecMediaRecoverySnapshot(
            generation: generation,
            phase: phase,
            missing: missingMediaLocked(),
            reconnectUsed: reconnectUsed,
            deadlineToken: deadlineToken
        )
    }

    private func missingMediaLocked() -> ParsecMissingMedia {
        switch (media.video, media.audio) {
        case (true, true): return .none
        case (false, true): return .video
        case (true, false): return .audio
        case (false, false): return .videoAndAudio
        }
    }

    private func publishIfChanged() {
        lock.lock()
        let next = snapshotLocked()
        guard next != lastPublishedSnapshot else {
            lock.unlock()
            return
        }
        lastPublishedSnapshot = next
        lock.unlock()

        logger.record(next)
        NotificationCenter.default.post(
            name: .parsecMediaRecoveryDidChange,
            object: next
        )
    }
}
