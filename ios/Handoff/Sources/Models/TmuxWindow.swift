import Foundation

/// A window (tab) within a tmux session.
/// Parsed from: tmux list-windows -t '$session' -F '#{window_index}|#{pane_title}|#{pane_current_command}|#{pane_current_path}'
struct TmuxWindow: Identifiable {
    let index: Int
    let title: String
    let command: String
    let cwd: String

    var id: Int { index }

    /// Display name: prefer pane title, fall back to running command.
    var displayName: String {
        if !title.isEmpty && title != command {
            return title
        }
        return command
    }

    init(index: Int, title: String, command: String, cwd: String = "") {
        self.index = index
        self.title = title
        self.command = command
        self.cwd = cwd
    }
}
