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
    @State private var hostKeyMismatch: HostKeyMismatchError?

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
    @State private var showSettings = false
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
    /// Silent refresh runs outside the explicit reload path, so it needs its
    /// own handle. Otherwise a stale pre-background refresh can finish after
    /// foreground recovery starts and either overwrite the fresh list or
    /// disconnect the newly re-established SSH session from its catch block.
    @State private var refreshTask: Task<Void, Never>?

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
    enum ResumeState {
        case inactive
        case foregroundAttempt
        case retryingForeground
        case restartingTransport
    }
    @State private var resumeState: ResumeState = .inactive

    // New session dialog
    @State private var showNewSessionDialog = false
    @State private var newSessionName = ""
    @State private var filterText = ""
    @FocusState private var filterFieldFocused: Bool

    // Auto-refresh timer
    let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var totalWindows: Int {
        sessions.reduce(0) { $0 + $1.windows.count }
    }

    private var matchCount: Int {
        visibleSessions.reduce(0) { $0 + $1.windows.count }
    }

    private var visibleSessions: [TmuxSession] {
        sessions.compactMap { session in
            let filteredWindows = filterText.isEmpty
                ? session.windows
                : session.windows.filter { window in
                    window.displayName.localizedCaseInsensitiveContains(filterText)
                        || window.cwd.localizedCaseInsensitiveContains(filterText)
                }

            guard !filteredWindows.isEmpty else { return nil }

            let sortedWindows = filteredWindows.sorted { lhs, rhs in
                let lhsPinned = configStore.isWindowPinned(session: session.name, title: lhs.title)
                let rhsPinned = configStore.isWindowPinned(session: session.name, title: rhs.title)
                if lhsPinned != rhsPinned {
                    return lhsPinned && !rhsPinned
                }
                return lhs.index < rhs.index
            }

            return TmuxSession(
                name: session.name,
                windowCount: session.windowCount,
                windows: sortedWindows
            )
        }
    }

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
                    mainContent
                    statusBar
                }
            }
        }
        .navigationTitle("Handoff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Unpair") {
                    unpairDevice()
                }
                .foregroundColor(Theme.red)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .foregroundColor(Theme.primary)

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
                    // Escalate recovery one level higher than SSH. Real-device
                    // testing still shows cases where the embedded Tailscale
                    // loopback itself is stale after backgrounding, so
                    // reconnecting SSH on top of the old proxy just burns 10s
                    // and surfaces "The request timed out". Restarting the
                    // transport re-routes through ContentView's Tailscale gate,
                    // then SessionsView is recreated and loads fresh.
                    resumeState = .inactive
                    loadTask?.cancel()
                    loadTask = nil
                    refreshTask?.cancel()
                    refreshTask = nil
                    sshManager.disconnect()
                    tailscale.restart()
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
        .sheet(item: $sshManager.pendingTrust) { request in
            HostKeyTrustPromptView(
                request: request,
                onTrust: { sshManager.approveTrust(request) },
                onReject: { sshManager.rejectTrust(request) }
            )
        }
        .fullScreenCover(item: $hostKeyMismatch) { mismatch in
            HostKeyMismatchView(
                error: mismatch,
                onCancel: {
                    hostKeyMismatch = nil
                },
                onResetTrust: {
                    sshManager.resetTrust(forHost: mismatch.host)
                    hostKeyMismatch = nil
                    forceReload()
                }
            )
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
        .sheet(isPresented: $showSettings) {
            SettingsView(
                config: configStore.config ?? ConnectionConfig(ip: "", user: "", privateKey: "", tmuxPath: ""),
                readOnly: readOnly,
                onDone: { showSettings = false },
                onSignOutOfTailscale: {
                    showSettings = false
                    signOutOfTailscale()
                },
                onUnpair: {
                    showSettings = false
                    unpairDevice()
                }
            )
            .environmentObject(configStore)
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
        refreshTask?.cancel()
        refreshTask = nil
        TerminalSessionStore.shared.closeAll()
        sshManager.disconnect()
        // resetState() closes the Tailscale node and deletes the persisted state dir,
        // so the next start() requires fresh browser sign-in.
        tailscale.resetState()
        // Pop back to root — ContentView will now show TailscaleAuthView since
        // tailscale.state == .stopped (Sessions screen is only reachable when .connected).
        path.removeLast(path.count)
    }

    private func unpairDevice() {
        resumeState = .inactive
        loadTask?.cancel()
        loadTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        sshManager.disconnect()
        TerminalSessionStore.shared.closeAll()
        configStore.unpair()
        path.removeLast(path.count)
    }

    // MARK: - Subviews

    private var mainContent: some View {
        Group {
            if sessions.isEmpty {
                emptyView
            } else {
                sessionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        let macIP = configStore.config?.ip ?? ""
        let statusColor = readOnly ? Theme.primary : Theme.green
        return HStack(spacing: 0) {
            Text("●")
                .foregroundColor(statusColor)
                .font(.system(size: 9))
                .padding(.trailing, 8)

            Text(readOnly ? "read-only" : "connected")
                .foregroundColor(statusColor)
                .font(.system(size: 12, design: .monospaced))

            separatorDot

            Button {
                UIPasteboard.general.string = macIP
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Text(macIP)
                    .foregroundColor(Theme.textSecondary)
                    .font(.system(size: 12, design: .monospaced))
            }
            .buttonStyle(.plain)
            .disabled(macIP.isEmpty)

            separatorDot

            Text("\(totalWindows) \(totalWindows == 1 ? "tab" : "tabs")")
                .foregroundColor(Theme.textSecondary)
                .font(.system(size: 12, design: .monospaced))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard totalWindows >= 6 else { return }
                    filterFieldFocused = true
                }

            if isLoading {
                separatorDot
                Text("syncing")
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var separatorDot: some View {
        Text(" · ")
            .foregroundColor(Theme.textSecondary.opacity(0.4))
            .font(.system(size: 12, design: .monospaced))
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if totalWindows >= 6 {
                    filterRow
                }

                if visibleSessions.isEmpty {
                    emptyFilterState
                } else {
                    ForEach(visibleSessions) { session in
                        SessionCard(
                            session: session,
                            readOnly: readOnly,
                            isWindowPinned: { window in
                                configStore.isWindowPinned(session: session.name, title: window.title)
                            },
                            onToggleWindowPin: { window in
                                configStore.togglePinnedWindow(session: session.name, title: window.title)
                            },
                            onSelectWindow: { window in
                                path.append(ContentView.Route.terminal(
                                    session: session.name,
                                    window: window.index,
                                    readOnly: readOnly
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

    private var filterRow: some View {
        HStack(spacing: 0) {
            Text("/")
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(Theme.primary.opacity(0.7))
                .padding(.trailing, 10)

            TextField("filter tabs by name or path", text: $filterText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundColor(Theme.text)
                .focused($filterFieldFocused)

            if !filterText.isEmpty {
                Text("\(matchCount)/\(totalWindows)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)

                Button {
                    filterText = ""
                } label: {
                    Text("×")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            Text("No matching tabs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("Try a different title or working-directory filter.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Clear filter") {
                filterText = ""
            }
            .font(.system(size: 12))
            .foregroundColor(Theme.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
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
        refreshTask?.cancel()
        refreshTask = nil
        sshManager.disconnect()
        loadSessions()
    }

    private func loadSessions(forceReconnect: Bool = false) {
        guard let config = configStore.config else { return }

        // Defensively cancel any previous in-flight load so its catch block
        // can't race with this one and rewrite `errorMessage` on a dead
        // connection.
        loadTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil

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
                            window: window.index,
                            readOnly: readOnly
                        ))
                    }
                }
            } catch is CancellationError {
                // Superseded by a newer reload. Don't touch UI state — the
                // newer Task owns it now.
                return
            } catch let mismatch as HostKeyMismatchError {
                await MainActor.run {
                    if Task.isCancelled { return }
                    resumeState = .inactive
                    hostKeyMismatch = mismatch
                    errorMessage = nil
                    isLoading = false
                }
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
                let stateAfterFailure = await MainActor.run { () -> ResumeState in
                    resumeState
                }
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
                // If even the foreground retry failed, the problem is likely
                // lower than SSH: the embedded Tailscale loopback / routing
                // stack may still be stale after resume. Escalate from "retry
                // SSH" to "restart transport" automatically instead of
                // surfacing a timeout banner that manual Retry then fixes a few
                // seconds later.
                if stateAfterFailure == .retryingForeground {
                    await MainActor.run {
                        if Task.isCancelled { return }
                        resumeState = .restartingTransport
                        sshManager.disconnect()
                        tailscale.restart()
                    }
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
        guard refreshTask == nil,
              let config = configStore.config,
              sshManager.isConnected else { return }

        refreshTask = Task {
            defer {
                Task { @MainActor in
                    refreshTask = nil
                }
            }
            do {
                var discoveredSessions = try await sshManager.listSessions(tmuxPath: config.tmuxPath)
                try Task.checkCancellation()
                for i in discoveredSessions.indices {
                    let windows = try await sshManager.listWindows(
                        tmuxPath: config.tmuxPath,
                        session: discoveredSessions[i].name
                    )
                    discoveredSessions[i].windows = windows
                    try Task.checkCancellation()
                }
                await MainActor.run {
                    if Task.isCancelled { return }
                    sessions = discoveredSessions
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                // Silently ignore errors during auto-refresh, but tear down
                // the zombie channel so the next user-initiated load or
                // scenePhase bump reconnects cleanly instead of hitting the
                // exec timeout again.
                await MainActor.run {
                    if Task.isCancelled { return }
                    sshManager.disconnect()
                }
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
                        window: windowIndex,
                        readOnly: readOnly
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
