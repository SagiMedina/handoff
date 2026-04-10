import SwiftUI

/// Displays tmux sessions and windows from the remote Mac.
/// Connects via SSH, discovers sessions, and allows navigation to terminal.
struct SessionsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @Binding var path: NavigationPath

    @StateObject private var sshManager = SSHManager()
    @State private var sessions: [TmuxSession] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Theme.primary)
                    Text("Connecting...")
                        .foregroundColor(Theme.textSecondary)
                }
            } else if let error = errorMessage {
                errorView(error)
            } else if sessions.isEmpty {
                emptyView
            } else {
                sessionList
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Unpair") {
                    sshManager.disconnect()
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
                .disabled(isLoading)
            }
        }
        .onAppear {
            loadSessions()
        }
        .onDisappear {
            // TerminalView creates its own SSHManager, so we can safely disconnect discovery
            sshManager.disconnect()
        }
    }

    // MARK: - Subviews

    private var sessionList: some View {
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

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(Theme.textSecondary)
            Text("No tmux sessions running on your Mac.")
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("Start a terminal on your Mac first.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            Button("Refresh") {
                loadSessions()
            }
            .foregroundColor(Theme.primary)
            .padding(.top, 8)
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundColor(Theme.red)
            Text(message)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                loadSessions()
            }
            .foregroundColor(Theme.primary)
            .padding(.top, 8)
        }
    }

    // MARK: - Data loading

    private func loadSessions() {
        guard let config = configStore.config else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Connect if not already connected
                if !sshManager.isConnected {
                    try await sshManager.connect(config: config)
                }

                // List sessions
                var discoveredSessions = try await sshManager.listSessions(tmuxPath: config.tmuxPath)

                // Fetch windows for each session
                for i in discoveredSessions.indices {
                    let windows = try await sshManager.listWindows(
                        tmuxPath: config.tmuxPath,
                        session: discoveredSessions[i].name
                    )
                    discoveredSessions[i].windows = windows
                }

                await MainActor.run {
                    sessions = discoveredSessions
                    isLoading = false

                    // Auto-connect: single session + single window → skip picker
                    if discoveredSessions.count == 1,
                       discoveredSessions[0].windows.count == 1 {
                        let session = discoveredSessions[0]
                        let window = session.windows[0]
                        path.append(ContentView.Route.terminal(
                            session: session.name,
                            window: window.index
                        ))
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
