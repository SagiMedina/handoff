import SwiftUI

/// Displays a tmux session with its windows as tappable rows.
/// Supports: tap window to open, long-press window to kill, kill session, new window.
struct SessionCard: View {
    let session: TmuxSession
    let onSelectWindow: (TmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onKillSession: () -> Void
    let onKillWindow: (TmuxWindow) -> Void

    @State private var showKillSessionDialog = false
    @State private var windowToKill: TmuxWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(Theme.green)
                Text(session.name)
                    .font(.headline)
                    .foregroundColor(Theme.text)
                Spacer()
                Text("\(session.windowCount) window\(session.windowCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                Button {
                    showKillSessionDialog = true
                } label: {
                    Text("Kill")
                        .font(.caption)
                        .foregroundColor(Theme.red)
                }
            }
            .padding()

            Divider()
                .background(Theme.border)

            // Window list
            ForEach(session.windows) { window in
                Button {
                    onSelectWindow(window)
                } label: {
                    HStack {
                        Text("\(window.index)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 24)
                        Text(window.displayName)
                            .font(.body)
                            .foregroundColor(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .contextMenu {
                    Button(role: .destructive) {
                        windowToKill = window
                    } label: {
                        Label("Kill Window", systemImage: "xmark.circle")
                    }
                }

                if window.id != session.windows.last?.id {
                    Divider()
                        .background(Theme.border)
                        .padding(.leading, 48)
                }
            }

            // New window link
            Divider()
                .background(Theme.border)

            Button {
                onNewWindow()
            } label: {
                HStack {
                    Image(systemName: "plus")
                        .font(.caption)
                    Text("new window")
                        .font(.system(.body, design: .monospaced))
                }
                .foregroundColor(Theme.primary)
                .padding(.horizontal)
                .padding(.vertical, 14)
            }
        }
        .background(Theme.surface)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
        // Kill session confirmation
        .confirmationDialog(
            "Kill Session",
            isPresented: $showKillSessionDialog,
            titleVisibility: .visible
        ) {
            Button("Kill \"\(session.name)\"", role: .destructive) {
                onKillSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will close all windows in this session. Any running processes will be terminated.")
        }
        // Kill window confirmation
        .confirmationDialog(
            "Kill Window",
            isPresented: Binding(
                get: { windowToKill != nil },
                set: { if !$0 { windowToKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let window = windowToKill {
                Button("Kill \"\(window.displayName)\"", role: .destructive) {
                    onKillWindow(window)
                    windowToKill = nil
                }
            }
            Button("Cancel", role: .cancel) {
                windowToKill = nil
            }
        } message: {
            Text("Any running process in this window will be terminated.")
        }
    }
}
