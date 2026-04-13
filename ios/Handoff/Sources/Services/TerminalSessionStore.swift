import Foundation
import SwiftTerm
import UIKit

/// Holds the currently active terminal connection outside of any view's lifecycle.
/// This ensures navigating back to Sessions and returning to the same terminal
/// doesn't tear down the SSH connection or lose the SwiftTerm buffer.
@MainActor
final class TerminalSessionStore: ObservableObject {

    static let shared = TerminalSessionStore()

    /// Identifies a terminal session by `(sessionName, windowIndex)`.
    struct Key: Hashable {
        let sessionName: String
        let windowIndex: Int
    }

    /// Live state for a single active terminal.
    final class ActiveTerminal {
        let key: Key
        let sshManager: SSHManager
        let handler: TerminalChannelHandler
        /// SwiftTerm view kept alive across navigations to preserve buffer + scroll state.
        let terminalView: SwiftTerm.TerminalView

        init(
            key: Key,
            sshManager: SSHManager,
            handler: TerminalChannelHandler,
            terminalView: SwiftTerm.TerminalView
        ) {
            self.key = key
            self.sshManager = sshManager
            self.handler = handler
            self.terminalView = terminalView
        }
    }

    /// Currently active terminals, keyed by session:window.
    /// We keep them in a dict so multiple sessions can coexist in the future,
    /// though the MVP only shows one at a time.
    private(set) var active: [Key: ActiveTerminal] = [:]

    /// Retrieve the active terminal for a key, if any.
    func get(_ key: Key) -> ActiveTerminal? {
        active[key]
    }

    /// Register a new active terminal. If one already exists for the same key,
    /// it is closed first to prevent leaks from duplicate reconnect taps.
    func register(_ terminal: ActiveTerminal) {
        if let existing = active[terminal.key] {
            existing.sshManager.disconnect()
        }
        active[terminal.key] = terminal
        updateIdleTimer()
    }

    /// Tear down and remove a specific terminal.
    func close(_ key: Key) {
        if let terminal = active.removeValue(forKey: key) {
            terminal.sshManager.disconnect()
        }
        updateIdleTimer()
    }

    /// Tear down all active terminals. Called on unpair or app shutdown.
    func closeAll() {
        for (_, terminal) in active {
            terminal.sshManager.disconnect()
        }
        active.removeAll()
        updateIdleTimer()
    }

    // MARK: - Idle timer lifecycle

    /// Keep the screen awake only while at least one terminal is active.
    /// Reset to false when no terminals remain.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !active.isEmpty
    }
}
