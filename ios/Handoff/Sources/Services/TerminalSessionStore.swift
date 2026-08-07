import Foundation
import SwiftTerm
import UIKit

/// Tracks terminal-screen presentation independently from retained transports.
/// A terminal can remain cached after Back without keeping the phone awake.
struct TerminalScreenVisibility {
    private(set) var visibleScreenIDs: Set<UUID> = []

    var shouldDisableIdleTimer: Bool {
        !visibleScreenIDs.isEmpty
    }

    mutating func didAppear(_ id: UUID) {
        visibleScreenIDs.insert(id)
    }

    mutating func didDisappear(_ id: UUID) {
        visibleScreenIDs.remove(id)
    }

    func contains(_ id: UUID) -> Bool {
        visibleScreenIDs.contains(id)
    }
}

/// The server-side access mode under which a retained tmux attachment was
/// opened. A live socket is not sufficient for reuse: device permissions may
/// have changed while the user was on the Sessions screen, and only a fresh
/// gate attach can apply tmux's read-only flag.
enum TerminalAccessMode: Equatable {
    case readWrite
    case readOnly

    init(readOnly: Bool) {
        self = readOnly ? .readOnly : .readWrite
    }

    func isCompatible(withReadOnly readOnly: Bool) -> Bool {
        self == TerminalAccessMode(readOnly: readOnly)
    }
}

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
        /// Distinguishes reconnect generations for the same tmux window. A
        /// delayed close callback from the old channel must not remove the
        /// newly registered terminal at the same Key.
        let id = UUID()
        let key: Key
        let sshManager: SSHManager
        let handler: TerminalChannelHandler
        let accessMode: TerminalAccessMode
        /// SwiftTerm view kept alive across navigations to preserve buffer + scroll state.
        let terminalView: SwiftTerm.TerminalView

        init(
            key: Key,
            sshManager: SSHManager,
            handler: TerminalChannelHandler,
            accessMode: TerminalAccessMode,
            terminalView: SwiftTerm.TerminalView
        ) {
            self.key = key
            self.sshManager = sshManager
            self.handler = handler
            self.accessMode = accessMode
            self.terminalView = terminalView
        }
    }

    /// The retained terminal, keyed by session:window. Android retains exactly
    /// one TerminalSession in its holder; keeping the dictionary-shaped API
    /// avoids churn at call sites while `register` enforces the same invariant.
    private(set) var active: [Key: ActiveTerminal] = [:]
    private var screenVisibility = TerminalScreenVisibility()

    /// Retrieve the active terminal for a key, if any.
    func get(_ key: Key) -> ActiveTerminal? {
        active[key]
    }

    /// Register the single retained terminal. Any other session/window is
    /// removed and disconnected first, matching Android's one-session holder.
    /// Reconnects may reuse one SSHManager, so only the superseded child channel
    /// is closed in that case; disconnecting the manager would kill the new
    /// generation as well.
    func register(_ terminal: ActiveTerminal) {
        let superseded = active.values.filter { $0.id != terminal.id }

        // Remove first so close callbacks triggered by teardown cannot remove
        // the replacement that is about to claim the same key.
        active.removeAll(keepingCapacity: true)
        active[terminal.key] = terminal

        for existing in superseded {
            if existing.sshManager === terminal.sshManager {
                existing.handler.channel?.close(promise: nil)
            } else {
                existing.sshManager.disconnect()
            }
        }
    }

    /// Tear down and remove a specific terminal.
    @discardableResult
    func close(_ key: Key) -> Bool {
        guard let terminal = active.removeValue(forKey: key) else { return false }
        terminal.sshManager.disconnect()
        return true
    }

    /// Tear down a terminal only if the callback belongs to the terminal that
    /// is still registered. Old channel-close callbacks commonly arrive after
    /// a reconnect has replaced the entry for the same key.
    @discardableResult
    func close(_ key: Key, ifMatching id: UUID) -> Bool {
        guard active[key]?.id == id else { return false }
        return close(key)
    }

    /// Tear down all active terminals. Called on unpair or app shutdown.
    func closeAll() {
        for (_, terminal) in active {
            terminal.sshManager.disconnect()
        }
        active.removeAll()
    }

    // MARK: - Visible screen lifecycle

    func terminalScreenDidAppear(_ id: UUID) {
        screenVisibility.didAppear(id)
        updateIdleTimer()
    }

    func terminalScreenDidDisappear(_ id: UUID) {
        screenVisibility.didDisappear(id)
        updateIdleTimer()
    }

    func isTerminalScreenVisible(_ id: UUID) -> Bool {
        screenVisibility.contains(id)
    }

    // MARK: - Idle timer lifecycle

    /// Keep the screen awake only while a terminal screen is actually visible.
    /// Retained SSH state and scrollback do not affect the device idle policy.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = screenVisibility.shouldDisableIdleTimer
    }
}
