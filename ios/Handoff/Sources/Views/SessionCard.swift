import SwiftUI

/// Displays a tmux session with its windows as tappable rows.
struct SessionCard: View {
    let session: TmuxSession
    let onSelectWindow: (TmuxWindow) -> Void

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
                    .padding(.vertical, 10)
                }

                if window.id != session.windows.last?.id {
                    Divider()
                        .background(Theme.border)
                        .padding(.leading, 48)
                }
            }
        }
        .background(Theme.surface)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}
