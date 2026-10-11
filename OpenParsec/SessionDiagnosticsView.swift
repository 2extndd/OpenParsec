import Combine
import SwiftUI

struct SessionDiagnosticsAccessibilityView: View {
    let exposesPhase: Bool
    @State private var snapshot: ParsecSessionSnapshot
    @State private var recovery: ParsecRecoverySnapshot
    @State private var mediaRecovery: ParsecMediaRecoverySnapshot
    @State private var pointerBehavior: ParsecPointerBehavior
    @State private var mouseInput: ParsecMouseInputSnapshot
    @State private var keyboardInput: ParsecKeyboardSnapshot
    @State private var gamepadInput: ParsecGamepadSnapshot
    @State private var shortcutExecution: ParsecShortcutExecutionSnapshot
    @State private var concurrency: ParsecConcurrencySnapshot
    @State private var transportRecovery: ParsecTransportRecoverySnapshot

    init(exposesPhase: Bool) {
        self.exposesPhase = exposesPhase
        _snapshot = State(initialValue: CParsec.sessionSnapshot)
        _recovery = State(initialValue: ParsecBackgroundManager.shared.recoverySnapshot)
        _mediaRecovery = State(initialValue: CParsec.mediaRecoverySnapshot)
        _pointerBehavior = State(
            initialValue: ParsecViewController.pointerBehaviorSnapshot
        )
        _mouseInput = State(initialValue: CParsec.mouseInputSnapshot)
        _keyboardInput = State(initialValue: CParsec.keyboardInputSnapshot)
        _gamepadInput = State(initialValue: CParsec.gamepadInputSnapshot)
        _shortcutExecution = State(initialValue: CParsec.shortcutExecutionSnapshot)
        _concurrency = State(initialValue: CParsec.concurrencySnapshot)
        _transportRecovery = State(initialValue: CParsec.transportRecoverySnapshot)
    }

    private var shortcutVisibility: ParsecHostShortcutVisibility {
        ParsecHostShortcutToolbarPolicy.visibility(
            mode: SettingsHandler.hostShortcutToolbarMode,
            host: CParsec.hostOS
        )
    }

    var body: some View {
        Group {
            if exposesPhase {
                Text(snapshot.phase.rawValue)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("openparsec.session.state")
            }
            Text(snapshot.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.session.diagnostics")
            Text(String(snapshot.generation))
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.session.generation")
            Text(recovery.state)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.recovery.state")
            Text(recovery.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.recovery.diagnostics")
            Text(mediaRecovery.phase.rawValue)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.media-recovery.state")
            Text(mediaRecovery.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.media-recovery.diagnostics")
            Text(pointerBehavior.mode == .native ? "native" : "captured")
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.pointer.state")
            Text(pointerBehavior.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.pointer.diagnostics")
            Text(String(mouseInput.pressedCount))
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.mouse-buttons.state")
            Text(mouseInput.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.mouse-buttons.diagnostics")
            Text(String(keyboardInput.pressedCount))
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.keyboard.state")
            Text(keyboardInput.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.keyboard.diagnostics")
            Text(String(gamepadInput.pressedCount))
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.gamepad.state")
            Text(gamepadInput.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.gamepad.diagnostics")
            Text(shortcutVisibility.showMac ? "enabled" : "disabled")
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.shortcuts.state")
            Text(
                "enabled=\(shortcutVisibility.showMac) "
                    + "coverage=\(ParsecMacShortcutCatalog.coverageCount) "
                    + shortcutExecution.digest
            )
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.shortcuts.diagnostics")
            Text(SettingsHandler.windowsKeyboardMode == .commandAsControl ? "command-as-control" : "direct")
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.windows.mode")
            Text(
                "mode=\(SettingsHandler.windowsKeyboardMode == .commandAsControl ? "command-as-control" : "direct") "
                    + "buttons=\(shortcutVisibility.showWindows) "
                    + "coverage=\(ParsecWindowsShortcutCatalog.coverageCount)"
            )
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.windows.diagnostics")
            Text(String(ParsecSettingsContract.coverageCount))
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.settings.coverage")
            Text(
                "count=\(ParsecSettingsContract.coverageCount) "
                    + "visible=\(ParsecSettingsContract.userVisibleControlCount) "
                    + "toolbar=\(SettingsHandler.hostShortcutToolbarMode.diagnosticName)"
            )
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.settings.diagnostics")
            Text(concurrency.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.concurrency.state")
            Text(transportRecovery.phase.rawValue)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.network-recovery.state")
            Text(transportRecovery.digest)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("openparsec.network-recovery.diagnostics")
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecConcurrencyDiagnosticsDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            concurrency = CParsec.concurrencySnapshot
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecTransportRecoveryDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecTransportRecoverySnapshot else {
                return
            }
            transportRecovery = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecSessionSnapshotDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecSessionSnapshot else { return }
            snapshot = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecRecoveryStateDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecRecoverySnapshot else { return }
            recovery = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecMediaRecoveryDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecMediaRecoverySnapshot else { return }
            mediaRecovery = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecPointerBehaviorDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecPointerBehavior else { return }
            pointerBehavior = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecMouseInputDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecMouseInputSnapshot else { return }
            mouseInput = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecKeyboardInputDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecKeyboardSnapshot else { return }
            keyboardInput = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecGamepadInputDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecGamepadSnapshot else { return }
            gamepadInput = next
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .parsecShortcutExecutionDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard let next = notification.object as? ParsecShortcutExecutionSnapshot else { return }
            shortcutExecution = next
        }
        .onAppear {
            pointerBehavior = ParsecViewController.pointerBehaviorSnapshot
            mouseInput = CParsec.mouseInputSnapshot
            keyboardInput = CParsec.keyboardInputSnapshot
            gamepadInput = CParsec.gamepadInputSnapshot
            shortcutExecution = CParsec.shortcutExecutionSnapshot
            concurrency = CParsec.concurrencySnapshot
        }
    }
}
