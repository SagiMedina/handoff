import SwiftUI

/// Displays a tmux session with its tabs (windows) as tappable rows.
/// Matches Sagi's polish (commit 967587d): cwd per tab, long-press on header
/// to kill session, dashed-border "+ new tab", wrapped titles, thin card border.
struct SessionCard: View {
    let session: TmuxSession
    let onSelectWindow: (TmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onKillSession: () -> Void
    let onKillWindow: (TmuxWindow) -> Void

    @State private var showKillSessionDialog = false
    @State private var windowToKill: TmuxWindow?

    private var tabsLabel: String { session.windowCount == 1 ? "tab" : "tabs" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header — long-press to kill
            HStack(spacing: 8) {
                Text("●")
                    .foregroundColor(Theme.green)
                    .font(.system(size: 10))
                Text(session.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("\(session.windowCount) \(tabsLabel)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .contentShape(Rectangle())
            .onLongPressGesture {
                showKillSessionDialog = true
            }

            Spacer().frame(height: 10)

            // Tab list
            if !session.windows.isEmpty {
                ForEach(Array(session.windows.enumerated()), id: \.element.id) { idx, window in
                    if idx > 0 {
                        Rectangle()
                            .fill(Theme.textSecondary.opacity(0.12))
                            .frame(height: 0.5)
                            .padding(.horizontal, 24)
                    }
                    WindowRow(
                        window: window,
                        onTap: { onSelectWindow(window) },
                        onLongPress: { windowToKill = window }
                    )
                }
            }

            Spacer().frame(height: 8)

            // "+ new tab" button — dashed border, distinct from list items
            Button(action: onNewWindow) {
                Text("+ new tab")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.primary.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                Theme.primary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.textSecondary.opacity(0.15), lineWidth: 0.5)
        )
        // Kill session confirmation
        .confirmationDialog(
            "Kill session?",
            isPresented: $showKillSessionDialog,
            titleVisibility: .visible
        ) {
            Button("Kill \"\(session.name)\"", role: .destructive) {
                onKillSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will close all \(session.windowCount) \(tabsLabel) in \"\(session.name)\".")
        }
        // Kill tab confirmation
        .confirmationDialog(
            "Kill tab?",
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
            if let window = windowToKill {
                Text("Close \"\(window.displayName)\" in session \"\(session.name)\"?")
            }
        }
    }
}

/// Two-line row: title + dimmed cwd. Tap to open, long-press to kill.
private struct WindowRow: View {
    let window: TmuxWindow
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("›")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                    Text(window.displayName)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !window.cwd.isEmpty {
                    Text("~/\(window.cwd)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary.opacity(0.6))
                        .lineLimit(1)
                        .padding(.leading, 22)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            onLongPress()
        }
    }
}
