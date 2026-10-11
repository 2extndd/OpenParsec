import OSLog
import UIKit

extension Notification.Name {
    static let parsecRecoveryStateDidChange = Notification.Name(
        "OpenParsec.ParsecRecoveryStateDidChange"
    )
}

struct ParsecRecoverySnapshot: Equatable, Sendable {
    let state: String
    let generation: UInt64
    let token: UInt64?

    var digest: String {
        "state=\(state) generation=\(generation) token=\(token.map(String.init) ?? "none")"
    }
}

struct BackgroundTaskToken: Equatable, Hashable, Sendable {
    let rawValue: Int
}

protocol BackgroundTaskAssertionProviding: AnyObject {
    func begin(name: String, expiration: @escaping () -> Void) -> BackgroundTaskToken?
    func end(_ token: BackgroundTaskToken)
}

protocol BackgroundScheduledTask: AnyObject {
    func cancel()
}

protocol BackgroundLifecycleScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> BackgroundScheduledTask
}

protocol ParsecBackgroundSessionControlling: AnyObject {
    func enterBackground()
    func enterBackgroundGrace()
    func resumeForeground()
    @discardableResult
    func disconnect(reason: ParsecDisconnectReason, generation: UInt64) -> Bool
}

struct ParsecReconnectRequest: Equatable {
    let peerID: String
    let generation: UInt64
    let token: UInt64
}

private final class UIApplicationBackgroundTaskProvider: BackgroundTaskAssertionProviding {
    private let lock = NSLock()
    private var tasks: [BackgroundTaskToken: UIBackgroundTaskIdentifier] = [:]

    func begin(name: String, expiration: @escaping () -> Void) -> BackgroundTaskToken? {
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: name,
            expirationHandler: {
                Diagnostics.note("background-assertion event=expired")
                expiration()
            }
        )
        guard identifier != .invalid else {
            Diagnostics.note("background-assertion result=invalid")
            return nil
        }
        guard UIApplication.shared.backgroundTimeRemaining > 0 else {
            Diagnostics.note("background-assertion result=no-time")
            UIApplication.shared.endBackgroundTask(identifier)
            return nil
        }
        Diagnostics.note("background-assertion result=acquired")
        let token = BackgroundTaskToken(rawValue: identifier.rawValue)
        lock.lock()
        tasks[token] = identifier
        lock.unlock()
        return token
    }

    func end(_ token: BackgroundTaskToken) {
        lock.lock()
        let identifier = tasks.removeValue(forKey: token)
        lock.unlock()
        guard let identifier else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

private final class DispatchBackgroundScheduledTask: BackgroundScheduledTask {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private final class MainQueueBackgroundScheduler: BackgroundLifecycleScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> BackgroundScheduledTask {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return DispatchBackgroundScheduledTask(workItem: workItem)
    }
}

private final class CParsecBackgroundSessionController: ParsecBackgroundSessionControlling {
    func enterBackground() {
        CParsec.enterBackground()
    }

    func enterBackgroundGrace() {
        CParsec.enterBackgroundGrace()
    }

    func resumeForeground() {
        CParsec.resumeForeground()
    }

    @discardableResult
    func disconnect(reason: ParsecDisconnectReason, generation: UInt64) -> Bool {
        CParsec.disconnect(reason: reason, generation: generation)
    }
}

class ParsecBackgroundManager {
    static let shared = ParsecBackgroundManager()

    private enum RecoveryState: Equatable {
        case idle
        case grace(peerID: String, generation: UInt64, token: UInt64)
        case reconnectPending(peerID: String, generation: UInt64)
        case reconnectScheduled(peerID: String, generation: UInt64, token: UInt64)

        var name: String {
            switch self {
            case .idle:
                return "idle"
            case .grace:
                return "grace"
            case .reconnectPending:
                return "reconnect-pending"
            case .reconnectScheduled:
                return "reconnect-scheduled"
            }
        }
    }

    private struct GraceResources {
        let task: BackgroundScheduledTask?
        let assertion: BackgroundTaskToken?
    }

    private struct GraceContext {
        let peerID: String
        let generation: UInt64
        let token: UInt64
    }

    private let lock = NSRecursiveLock()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenParsec",
        category: "background-recovery"
    )
    private let backgroundTasks: BackgroundTaskAssertionProviding
    private let scheduler: BackgroundLifecycleScheduling
    private let session: ParsecBackgroundSessionControlling
    private let gracePeriod: TimeInterval
    private let audioKeepAliveGracePeriod: TimeInterval
    private var backgroundAudioKeepAlive = false
    private let reconnectDelay: TimeInterval
    private let tracksResourceLedger: Bool

    private var activeConnection = false
    private var lastPeerID: String?
    private var lastConnectionGeneration: UInt64 = 0
    private var presentationPreservingBackgroundGeneration: UInt64?
    private var recoveryState: RecoveryState = .idle
    private var backgroundTaskToken: BackgroundTaskToken?
    private var graceTask: BackgroundScheduledTask?
    private var reconnectTask: BackgroundScheduledTask?
    private var nextToken: UInt64 = 0
    private var lastPublishedRecoverySnapshot: ParsecRecoverySnapshot?
    private var reconnectCallback: ((ParsecReconnectRequest) -> Void)?
    private var disconnectCallback: (() -> Void)?

    var onShouldReconnect: ((ParsecReconnectRequest) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return reconnectCallback
        }
        set {
            lock.lock()
            reconnectCallback = newValue
            lock.unlock()
        }
    }

    var onShouldDisconnect: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return disconnectCallback
        }
        set {
            lock.lock()
            disconnectCallback = newValue
            lock.unlock()
        }
    }

    private convenience init() {
        self.init(
            backgroundTasks: UIApplicationBackgroundTaskProvider(),
            scheduler: MainQueueBackgroundScheduler(),
            session: CParsecBackgroundSessionController(),
            gracePeriod: OpenParsecRuntime.backgroundGracePeriod,
            reconnectDelay: OpenParsecRuntime.backgroundReconnectDelay,
            tracksResourceLedger: true
        )
    }

    init(
        backgroundTasks: BackgroundTaskAssertionProviding,
        scheduler: BackgroundLifecycleScheduling,
        session: ParsecBackgroundSessionControlling,
        gracePeriod: TimeInterval,
        reconnectDelay: TimeInterval,
        audioKeepAliveGracePeriod: TimeInterval = 600,
        tracksResourceLedger: Bool = false
    ) {
        self.backgroundTasks = backgroundTasks
        self.scheduler = scheduler
        self.session = session
        self.gracePeriod = gracePeriod
        self.audioKeepAliveGracePeriod = audioKeepAliveGracePeriod
        self.reconnectDelay = reconnectDelay
        self.tracksResourceLedger = tracksResourceLedger
    }

    var hasActiveConnection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeConnection
    }

    var isReconnecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .reconnectScheduled = recoveryState { return true }
        return false
    }

    var isMarkedForReconnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        switch recoveryState {
        case .reconnectPending, .reconnectScheduled:
            return true
        case .idle, .grace:
            return false
        }
    }

    var shouldPreserveSessionPresentation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return presentationPreservingBackgroundGeneration != nil
    }

    var recoveryStateName: String {
        recoverySnapshot.state
    }

    var recoverySnapshot: ParsecRecoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return recoverySnapshotLocked()
    }

    var isPiPActive: Bool {
        if #available(iOS 15.0, *) {
            return PictureInPictureManager.shared.isPiPActive
        }
        return false
    }

    func connectionDidStart(peerId: String, generation: UInt64) {
        var graceResources = GraceResources(task: nil, assertion: nil)
        var replacementGrace: GraceContext?
        var taskToCancel: BackgroundScheduledTask?
        lock.lock()
        guard generation >= lastConnectionGeneration else {
            lock.unlock()
            return
        }
        activeConnection = true
        lastPeerID = peerId
        if let backgroundGeneration = presentationPreservingBackgroundGeneration,
           generation > backgroundGeneration {
            presentationPreservingBackgroundGeneration = nil
        }
        lastConnectionGeneration = generation
        switch recoveryState {
        case let .grace(_, graceGeneration, token):
            if generation == graceGeneration {
                recoveryState = .grace(peerID: peerId, generation: generation, token: token)
            } else {
                graceResources = takeGraceResourcesLocked()
                let replacementToken = makeTokenLocked()
                recoveryState = .grace(
                    peerID: peerId,
                    generation: generation,
                    token: replacementToken
                )
                replacementGrace = GraceContext(
                    peerID: peerId,
                    generation: generation,
                    token: replacementToken
                )
            }
        case .idle, .reconnectPending, .reconnectScheduled:
            taskToCancel = reconnectTask
            setReconnectTaskLocked(nil)
            recoveryState = .idle
        }
        lock.unlock()
        disposeGraceResources(graceResources)
        taskToCancel?.cancel()
        if let replacementGrace {
            installGraceResources(replacementGrace, reportSessionTransition: true)
        }
        publishRecoveryState()
    }

    func connectionAttemptDidFail(
        peerID: String,
        generation: UInt64,
        intent: ParsecConnectIntent
    ) {
        guard intent == .reconnect else {
            connectionDidEnd(generation: generation, reason: .user)
            return
        }

        var resources = GraceResources(task: nil, assertion: nil)
        var reconnectToCancel: BackgroundScheduledTask?
        lock.lock()
        guard generation == lastConnectionGeneration else {
            lock.unlock()
            return
        }
        resources = takeGraceResourcesLocked()
        reconnectToCancel = reconnectTask
        setReconnectTaskLocked(nil)
        nextToken &+= 1
        activeConnection = false
        lastPeerID = peerID
        recoveryState = .reconnectPending(peerID: peerID, generation: generation)
        lock.unlock()
        disposeGraceResources(resources)
        reconnectToCancel?.cancel()
        publishRecoveryState()
    }

    func reconnectAttemptDidFail(peerID: String, generation: UInt64) {
        lock.lock()
        guard generation == lastConnectionGeneration,
              activeConnection,
              lastPeerID == peerID else {
            lock.unlock()
            return
        }
        nextToken &+= 1
        recoveryState = .reconnectPending(peerID: peerID, generation: generation)
        activeConnection = false
        lock.unlock()
        publishRecoveryState()
        _ = session.disconnect(reason: .transportFailure, generation: generation)
    }

    func connectionDidEnd(
        generation: UInt64,
        reason: ParsecDisconnectReason = .transportFailure
    ) {
        var resources = GraceResources(task: nil, assertion: nil)
        var reconnectToCancel: BackgroundScheduledTask?
        var callback: (() -> Void)?
        lock.lock()
        guard generation == lastConnectionGeneration else {
            lock.unlock()
            return
        }
        activeConnection = false
        resources = takeGraceResourcesLocked()
        reconnectToCancel = reconnectTask
        setReconnectTaskLocked(nil)
        if reason == .backgroundExpired || reason == .transportFailure,
           let lastPeerID {
            if case .reconnectPending = recoveryState {
                // A manager-owned disconnect claimed recovery before invoking CParsec.
            } else {
                recoveryState = .reconnectPending(
                    peerID: lastPeerID,
                    generation: generation
                )
                callback = disconnectCallback
            }
        } else {
            nextToken &+= 1
            recoveryState = .idle
            lastPeerID = nil
        }
        lock.unlock()
        disposeGraceResources(resources)
        reconnectToCancel?.cancel()
        callback?()
        publishRecoveryState()
    }

    func sceneWillResignActive() {
    }

    func foregroundTransportRemainedUsable(generation: UInt64) {
        lock.lock()
        if presentationPreservingBackgroundGeneration == generation {
            presentationPreservingBackgroundGeneration = nil
        }
        lock.unlock()
    }

    /// Foreground decoder-loss recovery reconnects to the same host/output, so
    /// keep the session view up exactly like a background return does. The
    /// replacement generation's connectionDidStart clears it.
    func preserveSessionPresentation(generation: UInt64) {
        lock.lock()
        if activeConnection, generation == lastConnectionGeneration {
            presentationPreservingBackgroundGeneration = generation
        }
        lock.unlock()
    }

    /// - Parameter audioKeepAlive: the session's audio queue is playing, so
    ///   iPadOS keeps the process (and the SDK connection) running in the
    ///   background; no ~30 s task assertion is needed and the grace window
    ///   only caps battery/host use instead of racing suspension.
    func sceneDidEnterBackground(pipProtected: Bool, audioKeepAlive: Bool = false) {
        lock.lock()
        let shouldReportBackground = activeConnection
        if shouldReportBackground {
            presentationPreservingBackgroundGeneration = lastConnectionGeneration
        }
        backgroundAudioKeepAlive = audioKeepAlive
        lock.unlock()
        Diagnostics.note(
            "background-lifecycle event=did-enter active=\(shouldReportBackground) pip=\(pipProtected) audioKeepAlive=\(audioKeepAlive)"
        )
        guard shouldReportBackground else { return }

        session.enterBackground()
        if !pipProtected {
            beginBackgroundGrace()
        }
    }

    func pictureInPictureDidStart(generation: UInt64) {
        var resources = GraceResources(task: nil, assertion: nil)
        var canceledGrace = false
        lock.lock()
        if case let .grace(_, graceGeneration, _) = recoveryState,
           generation == graceGeneration {
            resources = takeGraceResourcesLocked()
            recoveryState = .idle
            canceledGrace = true
        }
        lock.unlock()
        guard canceledGrace else { return }

        disposeGraceResources(resources)
        session.enterBackground()
        publishRecoveryState()
    }

    func pictureInPictureProtectionEnded(
        whileBackgrounded: Bool,
        generation: UInt64
    ) {
        guard whileBackgrounded else { return }
        beginBackgroundGrace(expectedGeneration: generation)
    }

    @discardableResult
    func transportBecameUnusable(generation: UInt64) -> Bool {
        var resources = GraceResources(task: nil, assertion: nil)
        var reconnectToCancel: BackgroundScheduledTask?
        var callback: (() -> Void)?
        lock.lock()
        guard generation == lastConnectionGeneration,
              activeConnection,
              let lastPeerID else {
            lock.unlock()
            return false
        }
        resources = takeGraceResourcesLocked()
        reconnectToCancel = reconnectTask
        setReconnectTaskLocked(nil)
        nextToken &+= 1
        recoveryState = .reconnectPending(
            peerID: lastPeerID,
            generation: generation
        )
        activeConnection = false
        callback = disconnectCallback
        lock.unlock()

        disposeGraceResources(resources)
        reconnectToCancel?.cancel()
        publishRecoveryState()
        let disconnected = session.disconnect(
            reason: .transportFailure,
            generation: generation
        )
        if disconnected {
            callback?()
        }
        return disconnected
    }

    func sceneDidBecomeActive() {
        Diagnostics.note("background-lifecycle event=did-become-active")
        session.resumeForeground()

        var resources = GraceResources(task: nil, assertion: nil)
        var reconnect: (peerID: String, generation: UInt64, token: UInt64)?
        lock.lock()
        switch recoveryState {
        case .grace:
            resources = takeGraceResourcesLocked()
            recoveryState = .idle
        case let .reconnectPending(peerID, generation):
            let token = makeTokenLocked()
            recoveryState = .reconnectScheduled(
                peerID: peerID,
                generation: generation,
                token: token
            )
            reconnect = (peerID, generation, token)
        case .reconnectScheduled, .idle:
            break
        }
        lock.unlock()

        disposeGraceResources(resources)
        if let reconnect {
            installReconnectTask(
                peerID: reconnect.peerID,
                generation: reconnect.generation,
                token: reconnect.token
            )
        }
        publishRecoveryState()
    }

    /// Schedules an already-pending recovery while the app remains active.
    /// The state transition to reconnectScheduled is atomic, so foreground
    /// callbacks and active-session transport recovery cannot schedule twice.
    func schedulePendingReconnect() {
        var reconnect: (peerID: String, generation: UInt64, token: UInt64)?
        lock.lock()
        if case let .reconnectPending(peerID, generation) = recoveryState {
            let token = makeTokenLocked()
            recoveryState = .reconnectScheduled(
                peerID: peerID,
                generation: generation,
                token: token
            )
            reconnect = (peerID, generation, token)
        }
        lock.unlock()

        if let reconnect {
            installReconnectTask(
                peerID: reconnect.peerID,
                generation: reconnect.generation,
                token: reconnect.token
            )
        }
        publishRecoveryState()
    }

    func beginBackgroundGrace(expectedGeneration: UInt64? = nil) {
        var context: GraceContext?
        lock.lock()
        if activeConnection,
           expectedGeneration == nil || expectedGeneration == lastConnectionGeneration,
           let peerID = lastPeerID,
           recoveryState == .idle {
            let token = makeTokenLocked()
            let generation = lastConnectionGeneration
            recoveryState = .grace(peerID: peerID, generation: generation, token: token)
            context = GraceContext(peerID: peerID, generation: generation, token: token)
        }
        lock.unlock()
        guard let context else { return }

        installGraceResources(context, reportSessionTransition: true)
        publishRecoveryState()
    }

    private func installGraceResources(
        _ context: GraceContext,
        reportSessionTransition: Bool
    ) {
        if reportSessionTransition {
            session.enterBackgroundGrace()
        }
        lock.lock()
        let audioKeepAlive = backgroundAudioKeepAlive
        lock.unlock()
        if !audioKeepAlive {
            let assertion = backgroundTasks.begin(name: "ParsecKeepAlive") { [weak self] in
                self?.expireBackgroundGrace(token: context.token)
            }
            guard let assertion else {
                expireBackgroundGrace(token: context.token)
                return
            }

            lock.lock()
            let acceptsAssertion = isActiveGraceTokenLocked(context.token)
            if acceptsAssertion {
                backgroundTaskToken = assertion
            }
            lock.unlock()
            guard acceptsAssertion else {
                backgroundTasks.end(assertion)
                return
            }
        }

        let period = audioKeepAlive ? audioKeepAliveGracePeriod : gracePeriod
        let scheduled = scheduler.schedule(after: period) { [weak self] in
            self?.expireBackgroundGrace(token: context.token)
        }
        lock.lock()
        let acceptsTask = isActiveGraceTokenLocked(context.token)
        if acceptsTask {
            setGraceTaskLocked(scheduled)
        }
        lock.unlock()
        if !acceptsTask {
            scheduled.cancel()
        }
    }

    func markForReconnect() {
        var resources = GraceResources(task: nil, assertion: nil)
        var reconnectToCancel: BackgroundScheduledTask?
        lock.lock()
        if let lastPeerID {
            resources = takeGraceResourcesLocked()
            reconnectToCancel = reconnectTask
            setReconnectTaskLocked(nil)
            nextToken &+= 1
            recoveryState = .reconnectPending(
                peerID: lastPeerID,
                generation: lastConnectionGeneration
            )
        }
        lock.unlock()
        disposeGraceResources(resources)
        reconnectToCancel?.cancel()
        publishRecoveryState()
    }

    func reconnectDidFail(_ request: ParsecReconnectRequest) {
        var taskToCancel: BackgroundScheduledTask?
        lock.lock()
        if recoveryState == .reconnectScheduled(
            peerID: request.peerID,
            generation: request.generation,
            token: request.token
        ) {
            taskToCancel = reconnectTask
            setReconnectTaskLocked(nil)
            recoveryState = .reconnectPending(
                peerID: request.peerID,
                generation: request.generation
            )
        }
        lock.unlock()
        taskToCancel?.cancel()
        publishRecoveryState()
    }

    func disableAutoReconnect() {
        var resources = GraceResources(task: nil, assertion: nil)
        var reconnectToCancel: BackgroundScheduledTask?
        lock.lock()
        resources = takeGraceResourcesLocked()
        reconnectToCancel = reconnectTask
        setReconnectTaskLocked(nil)
        nextToken &+= 1
        recoveryState = .idle
        lastPeerID = nil
        presentationPreservingBackgroundGeneration = nil
        activeConnection = false
        lock.unlock()
        disposeGraceResources(resources)
        reconnectToCancel?.cancel()
        publishRecoveryState()
    }

    private func expireBackgroundGrace(token: UInt64) {
        var resources = GraceResources(task: nil, assertion: nil)
        var callback: (() -> Void)?
        var shouldDisconnect = false
        lock.lock()
        var disconnectGeneration: UInt64?
        if case let .grace(peerID, generation, activeToken) = recoveryState,
           activeToken == token {
            resources = takeGraceResourcesLocked()
            recoveryState = .reconnectPending(peerID: peerID, generation: generation)
            activeConnection = false
            callback = disconnectCallback
            disconnectGeneration = generation
            shouldDisconnect = true
        }
        lock.unlock()
        guard shouldDisconnect else { return }

        publishRecoveryState()
        disposeGraceResources(resources)
        guard let disconnectGeneration else { return }
        let disconnected = session.disconnect(
            reason: .backgroundExpired,
            generation: disconnectGeneration
        )
        if disconnected {
            callback?()
        }
    }

    private func installReconnectTask(
        peerID: String,
        generation: UInt64,
        token: UInt64
    ) {
        let scheduled = scheduler.schedule(after: reconnectDelay) { [weak self] in
            self?.fireReconnect(peerID: peerID, generation: generation, token: token)
        }
        lock.lock()
        let acceptsTask = recoveryState == .reconnectScheduled(
            peerID: peerID,
            generation: generation,
            token: token
        )
        if acceptsTask {
            setReconnectTaskLocked(scheduled)
        }
        lock.unlock()
        if !acceptsTask {
            scheduled.cancel()
        }
    }

    private func fireReconnect(peerID: String, generation: UInt64, token: UInt64) {
        lock.lock()
        let matches = recoveryState == .reconnectScheduled(
            peerID: peerID,
            generation: generation,
            token: token
        )
        guard matches else {
            lock.unlock()
            return
        }
        // The scheduled task has fired, so retire its ledger entry before
        // invoking the callback. The callback may synchronously start a new
        // generation and must observe no stale timer resource.
        setReconnectTaskLocked(nil)
        let request = ParsecReconnectRequest(
            peerID: peerID,
            generation: generation,
            token: token
        )
        let callback = reconnectCallback
        lock.unlock()
        callback?(request)
    }

    private func isActiveGraceTokenLocked(_ token: UInt64) -> Bool {
        guard case let .grace(_, _, activeToken) = recoveryState else { return false }
        return activeToken == token
    }

    private func setGraceTaskLocked(_ task: BackgroundScheduledTask?) {
        guard tracksResourceLedger else {
            graceTask = task
            return
        }
        if graceTask == nil, task != nil {
            CParsec.recordTimerAdded()
        } else if graceTask != nil, task == nil {
            CParsec.recordTimerRemoved()
        }
        graceTask = task
    }

    private func setReconnectTaskLocked(_ task: BackgroundScheduledTask?) {
        guard tracksResourceLedger else {
            reconnectTask = task
            return
        }
        if reconnectTask == nil, task != nil {
            CParsec.recordTimerAdded()
        } else if reconnectTask != nil, task == nil {
            CParsec.recordTimerRemoved()
        }
        reconnectTask = task
    }

    private func takeGraceResourcesLocked() -> GraceResources {
        let resources = GraceResources(task: graceTask, assertion: backgroundTaskToken)
        setGraceTaskLocked(nil)
        backgroundTaskToken = nil
        return resources
    }

    private func disposeGraceResources(_ resources: GraceResources) {
        resources.task?.cancel()
        if let assertion = resources.assertion {
            backgroundTasks.end(assertion)
        }
    }

    private func recoverySnapshotLocked() -> ParsecRecoverySnapshot {
        switch recoveryState {
        case .idle:
            return ParsecRecoverySnapshot(
                state: recoveryState.name,
                generation: lastConnectionGeneration,
                token: nil
            )
        case let .grace(_, generation, token),
             let .reconnectScheduled(_, generation, token):
            return ParsecRecoverySnapshot(
                state: recoveryState.name,
                generation: generation,
                token: token
            )
        case let .reconnectPending(_, generation):
            return ParsecRecoverySnapshot(
                state: recoveryState.name,
                generation: generation,
                token: nil
            )
        }
    }

    private func publishRecoveryState() {
        lock.lock()
        let snapshot = recoverySnapshotLocked()
        guard snapshot != lastPublishedRecoverySnapshot else {
            lock.unlock()
            return
        }
        lastPublishedRecoverySnapshot = snapshot
        lock.unlock()

        Diagnostics.note("background-recovery \(snapshot.digest)")
        logger.info("recovery \(snapshot.digest, privacy: .public)")
        NotificationCenter.default.post(
            name: .parsecRecoveryStateDidChange,
            object: snapshot
        )
    }

    private func makeTokenLocked() -> UInt64 {
        nextToken &+= 1
        return nextToken
    }
}
