import Foundation

/// A window within a tmux session.
/// Parsed from: tmux list-windows -t '$session' -F '#{window_index}|#{pane_title}|#{pane_current_command}'
struct TmuxWindow: Identifiable {
    let index: Int
    let title: String
    let command: String

    var id: Int { index }

    /// Display name: prefer pane title, fall back to running command.
    var displayName: String {
        if !title.isEmpty && title != command {
            return title
        }
        return command
    }
}
