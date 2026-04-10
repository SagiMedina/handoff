import SwiftUI

/// Terminal screen wrapping SwiftTerm for tmux session display.
/// Full SwiftTerm + SSH integration in Phase 4.
struct TerminalView: View {
    let sessionName: String
    let windowIndex: Int

    @State private var isConnecting = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Attaching to \(sessionName):\(windowIndex)...")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
            } else {
                // TODO Phase 4: SwiftTerm UIViewRepresentable + MobileToolbar
                Text("Terminal placeholder")
                    .foregroundColor(Theme.text)
            }
        }
        .navigationTitle("\(sessionName):\(windowIndex)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // TODO Phase 4: SSH connect + tmux attach
            Task {
                try? await Task.sleep(for: .seconds(1))
                isConnecting = false
            }
        }
    }
}
