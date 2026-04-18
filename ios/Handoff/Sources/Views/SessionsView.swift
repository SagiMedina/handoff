import SwiftUI

/// Displays tmux sessions and tabs from the remote Mac.
/// Connects via SSH, discovers sessions, and allows navigation to terminal.
struct SessionsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @Binding var path: NavigationPath
    var tailscale: TailscaleManager

    @StateObject private var sshManager = SSHManager()
    @State private var sessions: [TmuxSession] = []
    @State private var softExpiredPrompt: GateError?

    /// Read-only from the gate's `#permissions:` header. v1 pairings and any
    /// pre-first-list state resolve to `false`, which is the safe default
    /// because the gate server-side is still authoritative.
    private var readOnly: Bool {
        sshManager.devicePermissions?.readOnly ?? false
    }
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Separate surface for successful/neutral messages. errorMessage only
    /// renders when sessions is empty, so it's the wrong place for, e.g., a
    /// "renewal requested" confirmation that lands after the list has loaded.
    @State private var noticeMessage: String?
    @State private var hasAutoConnected = false
    @State private var showSignOutConfirmation = false
    // Tracks a background→active transition so scenePhase can force a fresh
    // SSH + SOCKS5 handshake on foreground, matching what TerminalView does.
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    /// Handle of the in-flight load Task so we can cancel it on
    /// forceReload / scenePhase transitions. Swift Tasks survive iOS
    /// backgrounding: without cancellation, a stale Task's catch block runs
    /// on resume and rewrites `errorMessage` right after the scenePhase
    /// handler cleared it, leaving the banner stuck.
    @State private var loadTask: Task<Void, Never>?

    /// Explicit state machine for post-background recovery. tsnet needs a
    /// beat to rebuild routing after iOS unfreezes the app; without both a
    /// pre-connect warmup AND a one-shot retry, the first gate command
    /// hangs and the user sees "The request timed out".
    ///
    /// - `inactive`: steady state. No warmup, no retry.
    /// - `foregroundAttempt`: first load after scenePhase `.active`. Warmup
    ///   applied. A transport failure transitions to `retryingForeground`.
    /// - `retryingForeground`: the one-shot retry. Warmup still applied
    ///   (that's the whole point of the fix — previously the retry lost it).
    ///   Failure from here surfaces to the user; success returns to
    ///   `inactive`.
    enum ResumeState { case inactive, foregroundAttempt, retryingForeground }
    @State private var resumeState: ResumeState = .inactive

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
            } else {
                VStack(spacing: 0) {
                    connectedHeader
                    if sessions.isEmpty {
                        emptyView
                    } else {
                        sessionList
                    }
                }
            }
        }
        .navigationTitle("Handoff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Unpair") {
                    resumeState = .inactive
                    loadTask?.cancel()
                    loadTask = nil
                    sshManager.disconnect()
                    TerminalSessionStore.shared.closeAll()
                    configStore.unpair()
                    path.removeLast(path.count)
                }
                .foregroundColor(Theme.red)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isLoading {
                    // Visible feedback that refresh is in flight
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.primary)
                } else {
                    Button {
                        forceReload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundColor(Theme.primary)
                }
            }
        }
        .onAppear {
            // Full load only when we have no cached data (first entry into
            // Sessions). Re-entry from Terminal finds sessions already
            // populated — the 5s refresh timer keeps them fresh without a
            // spinner + potential stale-channel failure on every return.
            if sessions.isEmpty {
                loadSessions()
            }
        }
        // NOTE: no onDisappear disconnect. SwiftUI fires onDisappear when
        // this view is pushed-over (user navigates into Terminal) and that
        // used to tear down the Sessions SSH connection, so returning to
        // Sessions always hit a stale-channel reconnect. Explicit
        // teardown happens in the Unpair button and signOutOfTailscale;
        // TailscaleAuthView handles the true dismissal path via scenePhase.
        .onReceive(refreshTimer) { _ in
            if !isLoading {
                silentRefresh()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                wasBackgrounded = true
            case .active:
                if wasBackgrounded {
                    wasBackgrounded = false
                    // Nil the stale error banner *before* forceReload's async
                    // clear gets a chance to run. SwiftUI paints the
                    // pre-background state on the first frame after resume,
                    // so without this sync clear the user sees the old
                    // "request timed out" banner flash before the reload
                    // spinner takes over. Also reset sessions if the prior
                    // load had failed into an empty state, so we show the
                    // spinner instead of errorView.
                    errorMessage = nil
                    isLoading = true
                    // Enter the foreground-recovery state machine. The
                    // first attempt gets a 500ms warmup (tsnet wake-up),
                    // and a transport failure transitions to
                    // `.retryingForeground` which keeps the warmup on the
                    // retry too — the whole point of the enum is that the
                    // retry doesn't lose warmup context the way a single
                    // bool did.
                    resumeState = .foregroundAttempt
                    // iOS tore down the SOCKS5 proxy / SSH socket while we
                    // were backgrounded. Force a fresh handshake instead of
                    // trusting the stale `parentChannel.isActive`. Pass
                    // resetResumeState: false so we DON'T clobber the
                    // `.foregroundAttempt` we just set — otherwise the
                    // recovery path would run with no warmup and no retry
                    // budget.
                    forceReload(resetResumeState: false)
                }
            default:
                break
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
        .alert("Sign out of Tailscale?", isPresented: $showSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                signOutOfTailscale()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again on next launch. Your Mac pairing stays intact.")
        }
        // Gate reports the device's soft expiry has passed. The only
        // permitted gate command in this state is `renew`; we let the user
        // send it and surface the Mac's confirmation.
        .alert(
            "Access expired",
            isPresented: Binding(
                get: { softExpiredPrompt != nil },
                set: { if !$0 { softExpiredPrompt = nil } }
            ),
            presenting: softExpiredPrompt
        ) { _ in
            Button("Request renewal") { requestRenewal() }
            Button("Cancel", role: .cancel) { softExpiredPrompt = nil }
        } message: { gate in
            Text(ErrorMessages.friendlyGate(gate))
        }
        // Neutral/success notices (e.g. "Renewal requested") — shown as an
        // alert so they're visible regardless of whether the session list is
        // loaded. errorMessage can't serve here because errorView only renders
        // when sessions is empty.
        .alert(
            "Handoff",
            isPresented: Binding(
                get: { noticeMessage != nil },
                set: { if !$0 { noticeMessage = nil } }
            ),
            presenting: noticeMessage
        ) { _ in
            Button("OK", role: .cancel) { noticeMessage = nil }
        } message: { text in
            Text(text)
        }
    }

    private func requestRenewal() {
        softExpiredPrompt = nil
        Task {
            do {
                _ = try await sshManager.requestRenewal()
                await MainActor.run {
                    // Matches the canonical command the Mac prints — see
                    // bin/handoff's top-level alias list.
                    noticeMessage = "Renewal requested. Ask the Mac owner to approve with `handoff renew <name>`."
                }
            } catch {
                await MainActor.run {
                    errorMessage = ErrorMessages.friendlyAction("request renewal", error)
                }
            }
        }
    }

    private func signOutOfTailscale() {
        // Close any open terminals before tearing down the network
        resumeState = .inactive
        loadTask?.cancel()
        loadTask = nil
        TerminalSessionStore.shared.closeAll()
        sshManager.disconnect()
        // resetState() closes the Tailscale node and deletes the persisted state dir,
        // so the next start() requires fresh browser sign-in.
        tailscale.resetState()
        // Pop back to root — ContentView will now show TailscaleAuthView since
        // tailscale.state == .stopped (Sessions screen is only reachable when .connected).
        path.removeLast(path.count)
    }

    // MARK: - Subviews

    /// "● Connected" indicator. Tap opens a Menu with the Tailscale IP and
    /// Tailscale-scoped actions (Copy IP, Sign out of Tailscale).
    /// Per designer: Tailscale-scoped actions cluster under the Tailscale status indicator,
    /// keeping them separate from Unpair (which is SSH/pairing-scoped, top-left).
    private var connectedHeader: some View {
        let macIP = configStore.config?.ip ?? ""
        return Menu {
            Section {
                Text(macIP)
                    .font(.system(.body, design: .monospaced))
                Button {
                    UIPasteboard.general.string = macIP
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copy IP", systemImage: "doc.on.doc")
                }
            }
            Section {
                Button(role: .destructive) {
                    showSignOutConfirmation = true
                } label: {
                    Label("Sign out of Tailscale", systemImage: "person.crop.circle.badge.xmark")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("●")
                    .foregroundColor(Theme.green)
                    .font(.system(size: 10))
                Text("Connected")
                    .foregroundColor(Theme.green)
                    .font(.system(size: 12))
                if readOnly {
                    Text("READ-ONLY")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.textSecondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sessions) { session in
                    SessionCard(
                        session: session,
                        readOnly: readOnly,
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

                // Subtle "+ new session" — suppressed in read-only mode so
                // the user doesn't see a visible mutation affordance the gate
                // would reject server-side.
                if !readOnly {
                    Button {
                        newSessionName = ""
                        showNewSessionDialog = true
                    } label: {
                        Text("+ new session")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(Theme.textSecondary)
            Text("No tmux sessions on your Mac.")
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if !readOnly {
                Button {
                    newSessionName = ""
                    showNewSessionDialog = true
                } label: {
                    Text("+ new session")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Theme.primary)
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                forceReload()
            }
            .foregroundColor(Theme.primary)
            .padding(.top, 8)
        }
    }

    // MARK: - Data loading

    /// User-initiated refresh. Always force a fresh SSH connection — the
    /// existing one may look healthy (`parentChannel.isActive == true`) but
    /// in reality be torn down by iOS after backgrounding, in which case the
    /// next gate command hangs until the exec-level timeout.
    ///
    /// When invoked by the toolbar Retry button or an errorView Retry (i.e.
    /// `resetResumeState = true`), this also drops any foreground-recovery
    /// state — manual reloads shouldn't inherit post-background retry/
    /// warmup semantics.
    private func forceReload(resetResumeState: Bool = true) {
        if resetResumeState {
            resumeState = .inactive
        }
        loadTask?.cancel()
        loadTask = nil
        sshManager.disconnect()
        loadSessions()
    }

    private func loadSessions(forceReconnect: Bool = false) {
        guard let config = configStore.config else { return }

        // Defensively cancel any previous in-flight load so its catch block
        // can't race with this one and rewrite `errorMessage` on a dead
        // connection.
        loadTask?.cancel()

        if forceReconnect {
            sshManager.disconnect()
        }

        isLoading = true
        errorMessage = nil

        loadTask = Task {
            do {
                // Pre-connect breathing room when we're in foreground
                // recovery (either the first attempt or the one retry).
                // tsnet's routing takes a beat to wake, and connecting too
                // early produces either a hang (exec timeout) or a socket
                // teardown ("network connection was lost") depending on
                // how long we were backgrounded. Reading the enum (not
                // consuming it) lets BOTH attempts warm up — the previous
                // bool got consumed by the retry path and left attempt 2
                // without warmup.
                let inRecovery = await MainActor.run { resumeState != .inactive }
                if inRecovery {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    try Task.checkCancellation()
                }

                if !sshManager.isConnected {
                    // Embedded Tailscale mode: never SSH without a proxy config.
                    // Direct-dialing the Tailscale IP would fail (no system VPN).
                    guard let proxyConfig = tailscale.proxyConfig else {
                        throw TailscaleError.notConnected
                    }
                    let proxy = SSHManager.SOCKSProxy(
                        host: proxyConfig.host,
                        port: proxyConfig.port,
                        username: proxyConfig.username,
                        password: proxyConfig.password
                    )
                    try await sshManager.connect(config: config, proxy: proxy)
                }
                try Task.checkCancellation()

                var discoveredSessions = try await sshManager.listSessions(tmuxPath: config.tmuxPath)
                try Task.checkCancellation()

                for i in discoveredSessions.indices {
                    let windows = try await sshManager.listWindows(
                        tmuxPath: config.tmuxPath,
                        session: discoveredSessions[i].name
                    )
                    discoveredSessions[i].windows = windows
                }
                try Task.checkCancellation()

                await MainActor.run {
                    if Task.isCancelled { return }
                    sessions = discoveredSessions
                    isLoading = false
                    // We succeeded — exit foreground recovery. Any later
                    // failure (e.g., mid-session) isn't part of the resume
                    // race and shouldn't inherit its warmup/retry.
                    resumeState = .inactive

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
            } catch is CancellationError {
                // Superseded by a newer reload. Don't touch UI state — the
                // newer Task owns it now.
                return
            } catch let gate as GateError {
                // Lifecycle errors get dedicated recovery surfaces. For
                // everything else we show the friendly copy inline. Gate
                // errors are structured protocol responses — not a transport
                // hiccup — so the resume-retry path doesn't apply here.
                await MainActor.run {
                    // Cancelled tasks mustn't mutate state — they've been
                    // superseded by a newer reload whose writes we'd clobber.
                    if Task.isCancelled { return }
                    resumeState = .inactive
                    isLoading = false
                    switch gate.code {
                    case .softExpired:
                        softExpiredPrompt = gate
                        errorMessage = nil
                    case .notFound:
                        // Mac has no record of this device — strongest hint
                        // is to unpair so the user can re-scan.
                        errorMessage = ErrorMessages.friendlyGate(gate)
                    default:
                        errorMessage = ErrorMessages.friendlyGate(gate)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                #if DEBUG
                print("[SessionsView] loadSessions threw: \(type(of: error)) — \(error.localizedDescription)")
                #endif
                // Post-resume retry: transition foregroundAttempt →
                // retryingForeground and try again. Reading the enum lets
                // the inner Task apply warmup on this attempt too — which
                // the old single-bool couldn't do because the retry
                // consumed the flag before the inner read.
                let shouldRetry = await MainActor.run { () -> Bool in
                    if resumeState == .foregroundAttempt {
                        resumeState = .retryingForeground
                        return true
                    }
                    return false
                }
                if shouldRetry {
                    sshManager.disconnect()
                    // 800ms backoff + 500ms warmup in the inner Task gives
                    // tsnet ~1.3s to settle before the retry connect.
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if Task.isCancelled { return }
                    await MainActor.run { loadSessions(forceReconnect: true) }
                    return
                }
                await MainActor.run {
                    if Task.isCancelled { return }
                    resumeState = .inactive
                    errorMessage = ErrorMessages.friendlyConnection(error)
                    isLoading = false
                }
            }
        }
    }

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
                // Silently ignore errors during auto-refresh, but tear down
                // the zombie channel so the next user-initiated load or
                // scenePhase bump reconnects cleanly instead of hitting the
                // exec timeout again.
                await MainActor.run { sshManager.disconnect() }
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
                errorMessage = ErrorMessages.friendlyAction("create session", error)
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
                errorMessage = ErrorMessages.friendlyAction("create tab", error)
            }
        }
    }

    private func killSession(_ session: TmuxSession) {
        guard let config = configStore.config else { return }

        Task {
            do {
                for window in session.windows {
                    TerminalSessionStore.shared.close(
                        .init(sessionName: session.name, windowIndex: window.index)
                    )
                }
                try await sshManager.killSession(tmuxPath: config.tmuxPath, name: session.name)
                loadSessions()
            } catch {
                errorMessage = ErrorMessages.friendlyAction("kill session", error)
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
                errorMessage = ErrorMessages.friendlyAction("kill tab", error)
            }
        }
    }
}
