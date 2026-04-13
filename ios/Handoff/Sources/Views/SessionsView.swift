import SwiftUI

/// Displays tmux sessions and windows from the remote Mac.
/// Connects via SSH, discovers sessions, and allows navigation to terminal.
struct SessionsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @Binding var path: NavigationPath
    var tailscale: TailscaleManager

    @StateObject private var sshManager = SSHManager()
    @State private var sessions: [TmuxSession] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasAutoConnected = false

    // New session dialog
    @State private var showNewSessionDialog = false
    @State private var newSessionName = ""

    // Auto-refresh timer
    let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isLoading && sessions.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Theme.primary)
                    Text("Connecting...")
                        .foregroundColor(Theme.textSecondary)
                }
            } else if let error = errorMessage, sessions.isEmpty {
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
                    TerminalSessionStore.shared.closeAll()
                    configStore.unpair()
                    path.removeLast(path.count)
                }
                .foregroundColor(Theme.red)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showNewSessionDialog = true
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundColor(Theme.primary)

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
            sshManager.disconnect()
        }
        .onReceive(refreshTimer) { _ in
            // Silent auto-refresh every 5s — no loading spinner
            if !isLoading {
                silentRefresh()
            }
        }
        .alert("New Session", isPresented: $showNewSessionDialog) {
            TextField("Session name", text: $newSessionName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create") {
                createNewSession()
            }
            Button("Cancel", role: .cancel) {
                newSessionName = ""
            }
        } message: {
            Text("Enter a name for the new tmux session.")
        }
    }

    // MARK: - Subviews

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sessions) { session in
                    SessionCard(
                        session: session,
                        onSelectWindow: { window in
                            path.append(ContentView.Route.terminal(
                                session: session.name,
                                window: window.index
                            ))
                        },
                        onNewWindow: {
                            createNewWindow(in: session)
                        },
                        onKillSession: {
                            killSession(session)
                        },
                        onKillWindow: { window in
                            killWindow(window, in: session)
                        }
                    )
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
            Text("Tap + to create one.")
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
                if !sshManager.isConnected {
                    // Route SSH through the embedded Tailscale proxy
                    let proxyPort = try tailscale.startProxy(targetIP: config.ip)
                    try await sshManager.connect(config: config, proxyPort: proxyPort)
                }

                var discoveredSessions = try await sshManager.listSessions(tmuxPath: config.tmuxPath)

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

                    if !hasAutoConnected,
                       discoveredSessions.count == 1,
                       discoveredSessions[0].windows.count == 1 {
                        hasAutoConnected = true
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

    /// Silent refresh — updates session list without showing a spinner.
    /// Used by the 5-second auto-refresh timer.
    private func silentRefresh() {
        guard let config = configStore.config, sshManager.isConnected else { return }

        Task {
            do {
                var discoveredSessions = try await sshManager.listSessions(tmuxPath: config.tmuxPath)
                for i in discoveredSessions.indices {
                    let windows = try await sshManager.listWindows(
                        tmuxPath: config.tmuxPath,
                        session: discoveredSessions[i].name
                    )
                    discoveredSessions[i].windows = windows
                }
                await MainActor.run {
                    sessions = discoveredSessions
                }
            } catch {
                // Silently ignore errors during auto-refresh
            }
        }
    }

    // MARK: - Session/window management

    private func createNewSession() {
        guard let config = configStore.config, !newSessionName.isEmpty else {
            newSessionName = ""
            return
        }

        let name = newSessionName
        newSessionName = ""

        Task {
            do {
                try await sshManager.createSession(tmuxPath: config.tmuxPath, name: name)
                loadSessions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createNewWindow(in session: TmuxSession) {
        guard let config = configStore.config else { return }

        Task {
            do {
                let windowIndex = try await sshManager.createWindow(
                    tmuxPath: config.tmuxPath,
                    session: session.name
                )
                await MainActor.run {
                    path.append(ContentView.Route.terminal(
                        session: session.name,
                        window: windowIndex
                    ))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func killSession(_ session: TmuxSession) {
        guard let config = configStore.config else { return }

        Task {
            do {
                // Close any active terminal for windows in this session
                for window in session.windows {
                    TerminalSessionStore.shared.close(
                        .init(sessionName: session.name, windowIndex: window.index)
                    )
                }
                try await sshManager.killSession(tmuxPath: config.tmuxPath, name: session.name)
                loadSessions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func killWindow(_ window: TmuxWindow, in session: TmuxSession) {
        guard let config = configStore.config else { return }

        Task {
            do {
                TerminalSessionStore.shared.close(
                    .init(sessionName: session.name, windowIndex: window.index)
                )
                try await sshManager.killWindow(
                    tmuxPath: config.tmuxPath,
                    session: session.name,
                    windowIndex: window.index
                )
                loadSessions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
