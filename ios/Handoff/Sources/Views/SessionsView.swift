import SwiftUI

/// Displays tmux sessions and windows from the remote Mac.
/// Full SSH integration in Phase 3.
struct SessionsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @Binding var path: NavigationPath

    @State private var sessions: [TmuxSession] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isLoading {
                ProgressView("Connecting...")
                    .foregroundColor(Theme.textSecondary)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.red)
                    Text(error)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        loadSessions()
                    }
                    .foregroundColor(Theme.primary)
                }
                .padding()
            } else if sessions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.textSecondary)
                    Text("No tmux sessions running on your Mac.")
                        .foregroundColor(Theme.textSecondary)
                    Button("Refresh") {
                        loadSessions()
                    }
                    .foregroundColor(Theme.primary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sessions) { session in
                            SessionCard(session: session) { window in
                                path.append(ContentView.Route.terminal(
                                    session: session.name,
                                    window: window.index
                                ))
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Unpair") {
                    configStore.unpair()
                    path.removeLast(path.count)
                }
                .foregroundColor(Theme.red)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    loadSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .foregroundColor(Theme.primary)
            }
        }
        .onAppear {
            loadSessions()
        }
    }

    private func loadSessions() {
        isLoading = true
        errorMessage = nil

        // TODO Phase 3: Replace with real SSH session discovery
        // SSHManager.shared.connect(configStore.config!) { ... }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                // Placeholder data for UI development
                sessions = [
                    TmuxSession(name: "main", windowCount: 2, windows: [
                        TmuxWindow(index: 0, title: "claude", command: "claude"),
                        TmuxWindow(index: 1, title: "vim", command: "nvim"),
                    ])
                ]
                isLoading = false
            }
        }
    }
}
