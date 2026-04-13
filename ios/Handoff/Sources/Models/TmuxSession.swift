import Foundation

/// A tmux session on the remote Mac.
/// Parsed from: tmux list-sessions -F '#{session_name}:#{session_windows}'
struct TmuxSession: Identifiable {
    let name: String
    let windowCount: Int
    var windows: [TmuxWindow]

    var id: String { name }
}
