import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

/// Tracks whether the current transport has completed SSH authentication.
/// `Channel.isActive` only describes the TCP socket; it can be true while a
/// SOCKS/SSH handshake is still pending or after a newer attempt superseded it.
final class SSHConnectionLifecycle {
    private let lock = NSLock()
    private var currentID: UUID?
    private var authenticatedID: UUID?

    var currentAttemptID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return currentID
    }

    var authenticatedAttemptID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedID
    }

    func begin() -> UUID {
        let id = UUID()
        lock.lock()
        currentID = id
        authenticatedID = nil
        lock.unlock()
        return id
    }

    @discardableResult
    func markAuthenticated(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentID == id else { return false }
        authenticatedID = id
        return true
    }

    func invalidate() {
        lock.lock()
        currentID = nil
        authenticatedID = nil
        lock.unlock()
    }

    func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentID == id
    }

    func isUsable(channelIsActive: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return channelIsActive
            && currentID != nil
            && authenticatedID == currentID
    }
}

/// Pure command construction for session discovery. Raw tmux uses exit status
/// 1 when no server is running; that is the valid "no sessions" result Android
/// already treats as an empty list, so only this v1 command normalizes it.
enum SSHDiscoveryCommand {
    static func listSessions(protocolVersion: Int, tmuxPath: String) -> String {
        protocolVersion >= 2
            ? "list"
            : "\(tmuxPath) list-sessions -F '#{session_name}:#{session_windows}' 2>/dev/null || true"
    }
}

/// Manages SSH connections to the remote Mac for tmux session discovery and terminal attachment.
///
/// Architecture (per codex review):
/// - Raw NIOSSH for full control over PTY channels and window-change requests
/// - OpenSSH private key parsing (QR payload is base64 of the full OpenSSH key file)
/// - Separate exec channels for discovery vs terminal attachment
final class SSHManager: ObservableObject {

    private var group: EventLoopGroup?
    // Internal access: TerminalChannel.swift extension needs these
    var parentChannel: Channel?
    var sshHandler: NIOSSHHandler?

    private var connectionLifecycle = SSHConnectionLifecycle()

    /// The active, authenticated SSH connection's channel, if connected.
    var isConnected: Bool {
        connectionLifecycle.isUsable(channelIsActive: parentChannel?.isActive ?? false)
    }

    // MARK: - Host-key TOFU state
    //
    // `pendingTrust` is surfaced to SwiftUI so first-trust can pause the SSH
    // handshake and ask the user to compare the fingerprint before continuing.
    @Published var pendingTrust: PendingTrustRequest?

    private var currentAttemptID: UUID?
    private var pendingTrustPromise: EventLoopPromise<Void>?
    private var pendingTrustEventLoop: EventLoop?
    private var pendingTrustTimeout: Scheduled<Void>?
    private let hostKeyStore: HostKeyStore = .shared
    private let trustPromptTimeoutSeconds: Int64 = 60

    // MARK: - Gate protocol state
    //
    // `protocolVersion` is lifted from the active ConnectionConfig at connect()
    // time. v1 = raw tmux commands over SSH; v2 = `handoff gate` forced-command
    // with per-device permissions and typed errors. Branching lives in each
    // high-level method so call sites are unchanged.
    private(set) var protocolVersion: Int = 1

    /// Permissions reported by the gate's `list` header (`#permissions:…`).
    /// Nil while disconnected or on v1 pairings. Updated on each `list` call.
    @Published var devicePermissions: DevicePermissions?

    // MARK: - Connect

    /// SOCKS5 proxy info for routing SSH through (e.g., Tailscale's loopback).
    struct SOCKSProxy {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    /// Connect to the remote Mac, optionally tunneled through a SOCKS5 proxy.
    /// When `proxy` is non-nil, the TCP socket goes to the SOCKS5 server and SOCKS5
    /// handshakes the actual connection to `config.ip:22`. SSH handlers are added
    /// only after the SOCKS handshake completes (via PostSOCKSUpgrader).
    /// Waits for both TCP connection AND SSH authentication to complete before returning.
    func connect(config: ConnectionConfig, proxy: SOCKSProxy? = nil) async throws {
        // Tear down any existing connection to prevent resource leaks on retry
        disconnect()

        // Capture the negotiated protocol version for the duration of this
        // connection so every downstream command branches consistently. v1 =
        // raw tmux over SSH; v2 = `handoff gate` forced-command with typed
        // errors and permission headers.
        self.protocolVersion = config.protocolVersion

        // Stamp this attempt so stale auth completions and @Published writes
        // cannot claim a newer connection.
        let connectionAttemptID = connectionLifecycle.begin()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        do {
            // The trust prompt uses the same attempt ID as the transport so a
            // tap from an abandoned handshake can never approve its successor.
            await MainActor.run {
                self.currentAttemptID = connectionAttemptID
                // Permissions belong to one authenticated gate connection.
                // Clear them at the new generation boundary so a v2 → v1
                // reconnect cannot retain the old device's read-only state.
                self.devicePermissions = nil
            }

            let privateKey = try parseOpenSSHKey(base64Encoded: config.privateKey)
            let authDelegate = PublicKeyAuthDelegate(
                username: config.user,
                privateKey: privateKey
            )

            // All possible handshake endings resolve through one idempotent
            // completion. In particular, the SOCKS handler can close before
            // PostSOCKSUpgrader installs AuthSuccessHandler; listening to the
            // parent channel's closeFuture below prevents that path from
            // waiting for the 75-second SSH auth timeout.
            let authCompletion = SSHAuthenticationCompletion(eventLoop: group.next())
            let authWaiter = AuthSuccessHandler(completion: authCompletion)

            let hostKeyValidator = TOFUHostKeyValidator(
                host: config.ip,
                attemptID: connectionAttemptID,
                store: hostKeyStore,
                onFirstTrust: { [weak self] request, promise in
                    let eventLoop = promise.futureResult.eventLoop
                    Task { @MainActor [weak self] in
                        guard let self else {
                            eventLoop.execute {
                                promise.fail(HostKeyValidationError.cancelled)
                            }
                            return
                        }
                        self.presentFirstTrust(
                            request: request,
                            promise: promise,
                            eventLoop: eventLoop
                        )
                    }
                },
                onMismatch: { error, promise in
                    promise.fail(error)
                }
            )

            let nioSSHHandler = NIOSSHHandler(
                role: .client(
                    .init(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: hostKeyValidator
                    )
                ),
                allocator: ByteBufferAllocator(),
                inboundChildChannelInitializer: nil
            )

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    if let proxy {
                        // SOCKS5 path: handshake first, then PostSOCKSUpgrader installs SSH
                        let socks = SOCKS5AuthConnectHandler(
                            username: proxy.username,
                            password: proxy.password,
                            targetHost: config.ip,
                            targetPort: 22
                        )
                        let upgrade = PostSOCKSUpgrader(
                            nioSSHHandler: nioSSHHandler,
                            authWaiter: authWaiter
                        )
                        return channel.pipeline.addHandlers([socks, upgrade])
                    } else {
                        // Direct path
                        return channel.pipeline.addHandlers([nioSSHHandler, authWaiter])
                    }
                }
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .connectTimeout(.seconds(15))

            let connectHost = proxy?.host ?? config.ip
            let connectPort = proxy?.port ?? 22
            let channel = try await bootstrap.connect(host: connectHost, port: connectPort).get()

            guard connectionLifecycle.isCurrent(connectionAttemptID) else {
                channel.close(promise: nil)
                throw CancellationError()
            }
            self.parentChannel = channel

            // We already hold a reference to the NIOSSHHandler we constructed.
            // Don't query the pipeline — in the SOCKS5 path it isn't installed until
            // PostSOCKSUpgrader runs after the handshake completes. Use our reference
            // directly; once the handler is added to the pipeline, it's the same object.
            self.sshHandler = nioSSHHandler

            channel.closeFuture.whenComplete { _ in
                authCompletion.fail(
                    SSHError.channelError("Connection closed before authentication")
                )
            }

            // Cap the SSH handshake + auth wait. After iOS backgrounds the app,
            // tsnet's SOCKS5 listener stays bound but WireGuard routing goes
            // silent: TCP connect completes, SOCKS handshake may succeed, yet no
            // SSH packets cross the tunnel. Without this timeout the caller
            // would block indefinitely — we want it to surface as an error that
            // triggers a reconnect. The scheduled task runs on the SSH event
            // loop, same rationale as executeCommand's timeout.
            // Keep this longer than the 60-second first-trust prompt. The socket
            // itself still has the independent 15-second ClientBootstrap timeout
            // above, so an unreachable host fails quickly while a person reading
            // and approving the fingerprint gets the full trust window.
            let authTimeout = channel.eventLoop.scheduleTask(in: .seconds(75)) {
                authCompletion.fail(SSHError.commandFailed("SSH authentication timed out"))
                channel.close(promise: nil)
            }
            authCompletion.futureResult.whenComplete { _ in
                authTimeout.cancel()
            }

            // EventLoopFuture.get() does not observe Swift Task cancellation.
            // Closing the attempt's channel makes cancellation promptly resolve
            // the auth future instead of allowing it to outlive a Retry.
            try await withTaskCancellationHandler {
                try await authCompletion.futureResult.get()
            } onCancel: {
                channel.close(promise: nil)
            }
            try Task.checkCancellation()

            guard connectionLifecycle.markAuthenticated(connectionAttemptID),
                  channel.isActive else {
                throw CancellationError()
            }
        } catch {
            // Only the failing attempt may tear down shared manager state. An
            // older cancelled Task can resume after a newer Retry has already
            // called connect(); it must not disconnect that newer connection.
            if connectionLifecycle.isCurrent(connectionAttemptID) {
                disconnect()
            }
            throw error
        }
    }

    // MARK: - Discovery (one-shot exec)

    /// List tmux sessions on the remote Mac. On v2 this goes through the
    /// gate's `list` command (which also emits a `#permissions:` header we
    /// stash on `devicePermissions`). On v1 we still shell raw tmux.
    func listSessions(tmuxPath: String) async throws -> [TmuxSession] {
        let command = SSHDiscoveryCommand.listSessions(
            protocolVersion: protocolVersion,
            tmuxPath: tmuxPath
        )
        let output = try await executeCommand(command)

        var lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // v2: consume the permissions header if present. We publish the parsed
        // value so UI can update its read-only / session-scope surfaces.
        // Guard against stale writes: capture the connection ID now and only
        // apply the update if we're still the active connection. Awaiting the
        // MainActor hop is fine — the calling Task is already async.
        if protocolVersion >= 2, let first = lines.first, first.hasPrefix("#permissions:") {
            let parsed = DevicePermissions.parse(header: first)
            let capturedID = connectionLifecycle.currentAttemptID
            await MainActor.run { [weak self] in
                guard let self,
                      self.connectionLifecycle.currentAttemptID == capturedID else { return }
                self.devicePermissions = parsed
            }
            lines.removeFirst()
        }

        // v2: a lone `error:*` line is a gate-level refusal, not an empty list.
        let trimmedJoined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if protocolVersion >= 2, let err = GateError.from(line: trimmedJoined) {
            throw err
        }

        let parsed: [TmuxSession] = lines.compactMap { line -> TmuxSession? in
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let windowCount = Int(parts[1]) else { return nil }
            return TmuxSession(
                name: String(parts[0]),
                windowCount: windowCount,
                windows: []
            )
        }

        // Distinguish a genuine empty session list from a lossy/truncated
        // post-resume response that failed to parse. Without this, a bad
        // `list` output silently returns [] — the UI replaces the cached
        // session list with nothing, and a later transport failure then
        // combines with errorMessage to render the full-screen error banner
        // instead of keeping the cached sessionList. (Diagnosis via codex.)
        let hasNonEmptyContent = lines.contains { !$0.isEmpty }
        if hasNonEmptyContent && parsed.isEmpty {
            #if DEBUG
            print("[SSHManager] listSessions: non-empty output failed to parse — treating as transport failure. Raw: \(trimmedJoined)")
            #endif
            throw SSHError.commandFailed("Unrecognized session list response")
        }

        return parsed
    }

    /// List windows (tabs) in a tmux session. v2 goes through `windows <sess>`;
    /// v1 shells raw tmux. The per-line wire format is identical for both paths.
    func listWindows(tmuxPath: String, session: String) async throws -> [TmuxWindow] {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        let command = protocolVersion >= 2
            ? "windows \(session)"
            : "\(tmuxPath) list-windows -t '\(escaped)' -F '#{window_index}|#{pane_title}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null"
        let output = try await executeCommand(command)

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if protocolVersion >= 2,
           let err = GateError.from(line: trimmedOutput) {
            throw err
        }

        let parsedWindows: [TmuxWindow] = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> TmuxWindow? in
                let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count >= 3,
                      let index = Int(parts[0]) else { return nil }

                let rawTitle = String(parts[1]).trimmingCharacters(in: .whitespaces)
                let command = String(parts[2]).trimmingCharacters(in: .whitespaces)
                let rawPath = parts.count >= 4 ? String(parts[3]) : ""

                // Title fallback: pane_title → pane_current_command → "shell"
                let candidate = rawTitle.isEmpty ? (command.isEmpty ? "shell" : command) : rawTitle
                // Strip leading non-letter/non-number chars (e.g., Claude Code status glyphs)
                let title = stripLeadingNonAlphanumeric(candidate)

                // cwd: take basename of the path
                let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let cwd = (trimmedPath as NSString).lastPathComponent == "/" ? "" : (trimmedPath as NSString).lastPathComponent

                return TmuxWindow(
                    index: index,
                    title: title.isEmpty ? "shell" : title,
                    command: command,
                    cwd: cwd
                )
            }

        // Same reasoning as listSessions: a malformed/truncated output that
        // doesn't look like an error but also doesn't parse into any windows
        // is almost certainly a transport hiccup (tsnet wake-up race), not a
        // session with zero windows. Treat it as a failure so the caller can
        // retry instead of caching an empty window list.
        if !trimmedOutput.isEmpty && parsedWindows.isEmpty {
            #if DEBUG
            print("[SSHManager] listWindows: non-empty output failed to parse. Raw: \(trimmedOutput)")
            #endif
            throw SSHError.commandFailed("Unrecognized window list response")
        }

        return parsedWindows
    }

    /// Strips leading characters that are not letters or numbers.
    /// Mirrors Android's regex `^[^\p{L}\p{N}]+`.
    private func stripLeadingNonAlphanumeric(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let first = scalars.first,
              !CharacterSet.letters.contains(first),
              !CharacterSet.decimalDigits.contains(first) {
            scalars.removeFirst()
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Session/window management

    /// Create a new tmux session.
    func createSession(tmuxPath: String, name: String) async throws {
        let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
        let command = protocolVersion >= 2
            ? "create-session \(name)"
            : "\(tmuxPath) new-session -d -s '\(escaped)'"
        let output = try await executeCommand(command)
        try throwIfGateError(output)
    }

    /// Kill an entire tmux session.
    func killSession(tmuxPath: String, name: String) async throws {
        let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
        let command = protocolVersion >= 2
            ? "kill-session \(name)"
            : "\(tmuxPath) kill-session -t '\(escaped)'"
        let output = try await executeCommand(command)
        try throwIfGateError(output)
    }

    /// Kill a single window within a tmux session.
    func killWindow(tmuxPath: String, session: String, windowIndex: Int) async throws {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        let command = protocolVersion >= 2
            ? "kill-window \(session) \(windowIndex)"
            : "\(tmuxPath) kill-window -t '\(escaped):\(windowIndex)'"
        let output = try await executeCommand(command)
        try throwIfGateError(output)
    }

    /// Create a new window in a tmux session. Returns the new window's index.
    func createWindow(tmuxPath: String, session: String) async throws -> Int {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        let command = protocolVersion >= 2
            ? "create-window \(session)"
            : "\(tmuxPath) new-window -t '\(escaped)' -P -F '#{window_index}'"
        let output = try await executeCommand(command)
        try throwIfGateError(output)
        guard let index = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SSHError.commandFailed("Could not parse window index from: \(output)")
        }
        return index
    }

    // MARK: - Gate-only commands

    /// Send `pair <deviceName>` to the gate during verification. The Mac
    /// responds with `verify:<6-digit code>`; callers display the code to the
    /// user who confirms it matches what `handoff pair` is showing on the Mac.
    /// Only meaningful on v2. Returns the raw wire string (including the
    /// `verify:` prefix) so tests can pin on the exact shape.
    func sendPairCommand(deviceName: String) async throws -> String {
        guard protocolVersion >= 2 else {
            throw SSHError.commandFailed("pair is only available on v2 pairings")
        }
        let safeDeviceName = PairingDeviceName.sanitize(deviceName)
        let output = try await executeCommand("pair \(safeDeviceName)")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        try throwIfGateError(trimmed)
        return trimmed
    }

    /// Request renewal when the device is soft-expired. Mac responds with
    /// `requested` on success. Only meaningful on v2.
    @discardableResult
    func requestRenewal() async throws -> String {
        guard protocolVersion >= 2 else {
            throw SSHError.commandFailed("renew is only available on v2 pairings")
        }
        let output = try await executeCommand("renew")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        try throwIfGateError(trimmed)
        return trimmed
    }

    /// Throws `GateError` if `output` starts with `error:` (only meaningful on
    /// v2 — a v1 tmux command never emits that prefix). Kept as a tiny helper
    /// so every gate-aware call site reads uniformly.
    private func throwIfGateError(_ output: String) throws {
        guard protocolVersion >= 2 else { return }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = GateError.from(line: trimmed) { throw err }
    }

    // MARK: - Host-key trust

    @MainActor
    func approveTrust(_ request: PendingTrustRequest) {
        guard request.id == currentAttemptID,
              let promise = pendingTrustPromise,
              let eventLoop = pendingTrustEventLoop else { return }
        hostKeyStore.trust(request.fingerprint, for: request.host)
        clearPendingTrustState()
        eventLoop.execute {
            promise.succeed(())
        }
    }

    @MainActor
    func rejectTrust(_ request: PendingTrustRequest) {
        guard request.id == currentAttemptID,
              let promise = pendingTrustPromise,
              let eventLoop = pendingTrustEventLoop else { return }
        clearPendingTrustState()
        eventLoop.execute {
            promise.fail(HostKeyValidationError.userRejected)
        }
    }

    @MainActor
    func resetTrust(forHost host: String) {
        hostKeyStore.forget(host: host)
    }

    @MainActor
    func hasTrustedHostKey(forHost host: String) -> Bool {
        hostKeyStore.hasTrust(for: host)
    }

    @MainActor
    private func presentFirstTrust(
        request: PendingTrustRequest,
        promise: EventLoopPromise<Void>,
        eventLoop: EventLoop
    ) {
        guard request.id == currentAttemptID else {
            eventLoop.execute {
                promise.fail(HostKeyValidationError.cancelled)
            }
            return
        }

        if let previousPromise = pendingTrustPromise, let previousEventLoop = pendingTrustEventLoop {
            previousEventLoop.execute {
                previousPromise.fail(HostKeyValidationError.cancelled)
            }
        }

        pendingTrustPromise = promise
        pendingTrustEventLoop = eventLoop
        pendingTrust = request

        pendingTrustTimeout?.cancel()
        pendingTrustTimeout = eventLoop.scheduleTask(in: .seconds(trustPromptTimeoutSeconds)) { [weak self] in
            promise.fail(HostKeyValidationError.timedOut)
            Task { @MainActor [weak self] in
                guard let self, self.pendingTrust?.id == request.id else { return }
                self.clearPendingTrustState()
            }
        }
    }

    @MainActor
    private func clearPendingTrustState() {
        pendingTrust = nil
        pendingTrustPromise = nil
        pendingTrustEventLoop = nil
        pendingTrustTimeout?.cancel()
        pendingTrustTimeout = nil
    }

    @MainActor
    private func invalidatePendingTrust(
        ifMatching attemptID: UUID?,
        reason: HostKeyValidationError = .cancelled
    ) {
        // disconnect() schedules this MainActor cleanup. A new connect can set
        // its trust attempt before that task runs, so only the retiring
        // generation is allowed to clear prompt state.
        let ownsCurrentAttempt = currentAttemptID == attemptID
        let ownsPendingPrompt = pendingTrust?.id == attemptID
        guard ownsCurrentAttempt || ownsPendingPrompt else { return }

        let pendingID = ownsPendingPrompt ? pendingTrust?.id : nil
        let promise = ownsPendingPrompt ? pendingTrustPromise : nil
        let eventLoop = ownsPendingPrompt ? pendingTrustEventLoop : nil

        if ownsCurrentAttempt {
            currentAttemptID = nil
        }
        if ownsPendingPrompt {
            pendingTrustPromise = nil
            pendingTrustEventLoop = nil
            pendingTrustTimeout?.cancel()
            pendingTrustTimeout = nil
        }

        if let promise, let eventLoop {
            eventLoop.execute {
                promise.fail(reason)
            }
        }

        guard let pendingID else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pendingTrust?.id == pendingID else { return }
            self.pendingTrust = nil
        }
    }

    // MARK: - Execute Command

    /// Execute a one-shot command over SSH and return stdout as a string.
    /// Creates a child session channel, sends exec request, collects output, closes.
    ///
    /// CRITICAL: NIOSSHHandler.createChannel() is not thread-safe — it MUST be called
    /// on the parent channel's event loop. We use flatSubmit to hop onto the right loop.
    /// NIOSSH internally buffers pending channel creations until SSH auth completes.
    private func executeCommand(_ command: String) async throws -> String {
        guard isConnected,
              let parentChannel = self.parentChannel,
              let sshHandler = self.sshHandler else {
            throw SSHError.notConnected
        }
        let usesGateProtocol = protocolVersion >= 2

        // iOS tears down the Tailscale SOCKS5 proxy while the app is
        // backgrounded. When the user returns, `parentChannel.isActive` can
        // still read as true even though the underlying socket is zombied —
        // `createChannel` then never fulfills the promise and we hang
        // forever. Cap the per-command wait by scheduling the timeout on the
        // event loop itself (so it fails the promise rather than trying to
        // cancel an `EventLoopFuture.get()` that, by NIO's docs, doesn't
        // honor Task cancellation).
        return try await withTaskCancellationHandler {
            try await parentChannel.eventLoop.flatSubmit { () -> EventLoopFuture<String> in
                let completion = SSHCommandCompletion(eventLoop: parentChannel.eventLoop)
                let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)
                var childChannel: Channel?

                // Fail the promise if the command hasn't completed in 10s.
                // Close any child and its parent so no timed-out channel can
                // linger and poison the next load.
                let timeoutTask = parentChannel.eventLoop.scheduleTask(in: .seconds(10)) {
                    completion.fail(SSHError.commandFailed("The request timed out"))
                    childChannel?.close(promise: nil)
                    parentChannel.close(promise: nil)
                }
                completion.futureResult.whenComplete { _ in
                    timeoutTask.cancel()
                }

                sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(
                            SSHError.channelError("Unexpected channel type")
                        )
                    }
                    return childChannel.pipeline.addHandler(
                        ExecChannelHandler(
                            command: command,
                            usesGateProtocol: usesGateProtocol,
                            completion: completion
                        )
                    )
                }

                channelPromise.futureResult.whenSuccess { channel in
                    if completion.isCompleted {
                        channel.close(promise: nil)
                    } else {
                        childChannel = channel
                    }
                }
                channelPromise.futureResult.whenFailure { error in
                    completion.fail(error)
                }

                return completion.futureResult
            }.get()
        } onCancel: {
            // NIO futures do not inherit Swift Task cancellation. Closing this
            // connection promptly resolves any pending createChannel/exec
            // future; the next explicit load establishes a fresh connection.
            parentChannel.close(promise: nil)
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        // Detach shared state synchronously so a subsequent connect cannot
        // observe or overwrite the retiring generation. Channel close and
        // event-loop shutdown are asynchronous; blocking with wait() /
        // syncShutdownGracefully() here stalls the MainActor on every Back or
        // Retry tap.
        let retiringChannel = parentChannel
        let retiringGroup = group
        let retiringTrustAttemptID = currentAttemptID
        parentChannel = nil
        sshHandler = nil
        group = nil
        // Reset gate state so a subsequent v1 pairing doesn't inherit stale v2
        // permissions from the prior session. Invalidating the connection ID
        // up-front means any still-in-flight @Published update from the last
        // connection will fail its guard check and be dropped.
        protocolVersion = 1
        connectionLifecycle.invalidate()
        // Trust state (pendingTrust/promise/attemptID/timeout) is MainActor-
        // isolated, so hop the teardown onto the main actor alongside the
        // permissions reset. This Task is enqueued before connect()'s own
        // `currentAttemptID` set (connect calls disconnect first), so the
        // FIFO main-actor executor clears the old attempt before the new one
        // lands; an in-flight first-trust prompt for the new connection is
        // therefore not invalidated.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.invalidatePendingTrust(ifMatching: retiringTrustAttemptID)
            if self.connectionLifecycle.currentAttemptID == nil {
                self.devicePermissions = nil
            }
        }

        guard let retiringGroup else { return }
        let shutdownQueue = DispatchQueue.global(qos: .utility)
        if let retiringChannel {
            retiringChannel.close().whenComplete { _ in
                retiringGroup.shutdownGracefully(queue: shutdownQueue) { error in
                    #if DEBUG
                    if let error {
                        print("[SSHManager] Event-loop shutdown failed: \(error)")
                    }
                    #endif
                }
            }
        } else {
            // This also cancels an in-progress ClientBootstrap attempt that
            // has not produced a parent channel yet.
            retiringGroup.shutdownGracefully(queue: shutdownQueue) { error in
                #if DEBUG
                if let error {
                    print("[SSHManager] Event-loop shutdown failed: \(error)")
                }
                #endif
            }
        }
    }

    // MARK: - Key Parsing

    /// Parse a base64-encoded OpenSSH private key into a Curve25519 signing key.
    /// The QR payload contains base64(OpenSSH key file text), not raw key bytes.
    private func parseOpenSSHKey(base64Encoded: String) throws -> Curve25519.Signing.PrivateKey {
        guard let keyFileData = Data(base64Encoded: base64Encoded) else {
            throw SSHError.invalidKey("Failed to base64-decode key")
        }

        guard let keyFileText = String(data: keyFileData, encoding: .utf8) else {
            throw SSHError.invalidKey("Key data is not valid UTF-8")
        }

        // OpenSSH private key format:
        // -----BEGIN OPENSSH PRIVATE KEY-----
        // <base64-encoded binary data>
        // -----END OPENSSH PRIVATE KEY-----
        let lines = keyFileText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }

        let innerBase64 = lines.joined()
        guard let binaryData = Data(base64Encoded: innerBase64) else {
            throw SSHError.invalidKey("Failed to decode inner key data")
        }

        return try parseOpenSSHBinary(binaryData)
    }

    /// Parse the binary OpenSSH private key format to extract the Ed25519 seed.
    /// Spec: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key
    private func parseOpenSSHBinary(_ data: Data) throws -> Curve25519.Signing.PrivateKey {
        var offset = 0

        func readBytes(_ count: Int) throws -> Data {
            guard offset + count <= data.count else {
                throw SSHError.invalidKey("Unexpected end of key data")
            }
            let result = data[offset..<(offset + count)]
            offset += count
            return Data(result)
        }

        func readUInt32() throws -> UInt32 {
            let bytes = try readBytes(4)
            // Safe unaligned read — do not use load(as:) on potentially unaligned Data
            return UInt32(bytes[bytes.startIndex]) << 24
                | UInt32(bytes[bytes.startIndex + 1]) << 16
                | UInt32(bytes[bytes.startIndex + 2]) << 8
                | UInt32(bytes[bytes.startIndex + 3])
        }

        func readString() throws -> Data {
            let length = try readUInt32()
            return try readBytes(Int(length))
        }

        // Magic: "openssh-key-v1\0"
        let magic = "openssh-key-v1\0"
        let magicBytes = try readBytes(magic.utf8.count)
        guard String(data: magicBytes, encoding: .utf8) == magic else {
            throw SSHError.invalidKey("Not an OpenSSH key (bad magic)")
        }

        // ciphername (should be "none" for unencrypted)
        let cipherName = try readString()
        guard String(data: cipherName, encoding: .utf8) == "none" else {
            throw SSHError.invalidKey("Encrypted keys are not supported")
        }

        // kdfname, kdf options (both "none"/empty for unencrypted)
        _ = try readString()
        _ = try readString()

        // Number of keys (always 1)
        let numKeys = try readUInt32()
        guard numKeys == 1 else {
            throw SSHError.invalidKey("Expected 1 key, found \(numKeys)")
        }

        // Public key blob (skip)
        _ = try readString()

        // Private section blob
        let privateBlob = try readString()

        // Parse private section with its own offset
        var privOffset = 0

        func privReadBytes(_ count: Int) throws -> Data {
            guard privOffset + count <= privateBlob.count else {
                throw SSHError.invalidKey("Unexpected end of private key data")
            }
            let result = privateBlob[privateBlob.startIndex.advanced(by: privOffset)..<privateBlob.startIndex.advanced(by: privOffset + count)]
            privOffset += count
            return Data(result)
        }

        func privReadUInt32() throws -> UInt32 {
            let bytes = try privReadBytes(4)
            // Safe unaligned read — do not use load(as:) on potentially unaligned Data
            return UInt32(bytes[bytes.startIndex]) << 24
                | UInt32(bytes[bytes.startIndex + 1]) << 16
                | UInt32(bytes[bytes.startIndex + 2]) << 8
                | UInt32(bytes[bytes.startIndex + 3])
        }

        func privReadString() throws -> Data {
            let length = try privReadUInt32()
            return try privReadBytes(Int(length))
        }

        // Two identical checkints (integrity verification)
        let check1 = try privReadUInt32()
        let check2 = try privReadUInt32()
        guard check1 == check2 else {
            throw SSHError.invalidKey("Key integrity check failed (bad passphrase?)")
        }

        // Key type string
        let keyType = try privReadString()
        guard String(data: keyType, encoding: .utf8) == "ssh-ed25519" else {
            let typeName = String(data: keyType, encoding: .utf8) ?? "unknown"
            throw SSHError.invalidKey("Expected ssh-ed25519, got \(typeName)")
        }

        // Ed25519 public key (32 bytes, skip)
        _ = try privReadString()

        // Ed25519 private key: 64 bytes = 32-byte seed + 32-byte public key
        let fullKey = try privReadString()
        guard fullKey.count == 64 else {
            throw SSHError.invalidKey("Expected 64-byte Ed25519 key, got \(fullKey.count)")
        }

        // First 32 bytes are the seed — this is what Curve25519.Signing.PrivateKey expects
        let seed = fullKey.prefix(32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    deinit {
        disconnect()
    }
}

/// Normalizes user-controlled `UIDevice.name` values before they enter the
/// gate command. Device names are display-only, so a deliberately small ASCII
/// alphabet avoids command separators, quotes, escapes, and control characters
/// while preserving ordinary names such as "Omri iPhone-15".
enum PairingDeviceName {
    static let maximumLength = 48
    static let fallback = "iPhone"

    static func sanitize(_ rawValue: String) -> String {
        let folded = rawValue.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let allowedPunctuation: Set<UnicodeScalar> = [" ", "-", "_", "."]
        var result = ""
        var pendingSeparator = false

        for scalar in folded.unicodeScalars {
            let isASCIIAlphaNumeric = scalar.isASCII
                && ((scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122))

            if isASCIIAlphaNumeric || allowedPunctuation.contains(scalar) {
                if pendingSeparator, !result.isEmpty, result.last != " " {
                    result.append(" ")
                }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }

            if result.count >= maximumLength {
                break
            }
        }

        let bounded = String(result.prefix(maximumLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return bounded.isEmpty ? fallback : bounded
    }
}

// MARK: - Error types

enum SSHError: LocalizedError {
    case notConnected
    case invalidKey(String)
    case authenticationRejected
    case commandFailed(String)
    case channelError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Mac. Check Tailscale."
        case .invalidKey(let reason):
            return "Invalid SSH key: \(reason)"
        case .authenticationRejected:
            return "This pairing key is no longer accepted by the Mac. Unpair and scan a new QR code from handoff pair."
        case .commandFailed(let reason):
            return "Command failed: \(reason)"
        case .channelError(let reason):
            return "SSH channel error: \(reason)"
        }
    }
}

// MARK: - Auth delegates

/// Tracks the single public-key offer allowed for one SSH connection attempt.
///
/// When sshd rejects a key it commonly advertises `publickey` again. Offering
/// the same key repeatedly only burns through MaxAuthTries, after which sshd
/// closes the socket and the UI sees a misleading generic channel error.
/// Failing the second challenge preserves the real, actionable cause.
final class PublicKeyAuthenticationAttempt {
    private var hasOfferedKey = false

    func claimKeyOffer() -> Bool {
        guard !hasOfferedKey else { return false }
        hasOfferedKey = true
        return true
    }
}

/// Public key authentication using Ed25519.
private final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let privateKey: Curve25519.Signing.PrivateKey
    private let attempt = PublicKeyAuthenticationAttempt()

    init(username: String, privateKey: Curve25519.Signing.PrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), attempt.claimKeyOffer() else {
            nextChallengePromise.fail(SSHError.authenticationRejected)
            return
        }

        nextChallengePromise.succeed(
            .init(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)))
            )
        )
    }
}

/// Accept all host keys for MVP (matching Android's StrictHostKeyChecking=no).
/// Isolated behind protocol per codex recommendation for future tightening.
protocol HostKeyValidator {
    func validate(hostKey: NIOSSHPublicKey) async -> Bool
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // TODO: Implement proper host key verification
        validationCompletePromise.succeed(())
    }
}

// MARK: - Auth success handler

/// Idempotent resolution for one SSH authentication attempt. SOCKS failure,
/// channel close, auth success, and timeout can converge on the same event-loop
/// turn; funnelling them through this object avoids double-completing a promise.
private final class SSHAuthenticationCompletion {
    let futureResult: EventLoopFuture<Void>

    private var promise: EventLoopPromise<Void>?

    init(eventLoop: EventLoop) {
        let promise = eventLoop.makePromise(of: Void.self)
        self.promise = promise
        self.futureResult = promise.futureResult
    }

    func succeed() {
        guard let promise else { return }
        self.promise = nil
        promise.succeed(())
    }

    func fail(_ error: Error) {
        guard let promise else { return }
        self.promise = nil
        promise.fail(error)
    }
}

/// Catches UserAuthSuccessEvent from NIOSSH and fulfills a promise.
/// Added to the parent channel pipeline so connect() can wait for auth before returning.
///
/// Promise completion is funneled through handlerRemoved() which NIO guarantees
/// is called exactly once for any handler added to a pipeline. This prevents the
/// EventLoopFuture.deinit assertion that fires if a promise is dropped unfulfilled.
private final class AuthSuccessHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let completion: SSHAuthenticationCompletion
    private var lastError: Error?

    init(completion: SSHAuthenticationCompletion) {
        self.completion = completion
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            completion.succeed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lastError = error
        failPendingPromise(with: error)
        context.fireErrorCaught(error)
        // NIOSSH reports a failed authentication-delegate future through the
        // pipeline but does not close the parent channel itself. Close here so
        // a rejected key cannot leave the socket and event-loop group alive
        // until sshd's LoginGraceTime expires.
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failPendingPromise(
            with: lastError ?? SSHError.channelError("Connection closed before authentication")
        )
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Safety net: if the handler is torn down and the promise was never fulfilled,
        // fail it so EventLoopFuture.deinit doesn't trap.
        failPendingPromise(
            with: lastError ?? SSHError.channelError("Connection closed before authentication")
        )
    }

    private func failPendingPromise(with error: Error) {
        completion.fail(error)
    }
}

// MARK: - Exec channel handler

/// Idempotent resolution for a one-shot SSH command. The exec timeout and the
/// channel failure/close callbacks can arrive together when a cancelled load
/// tears down its parent channel.
private final class SSHCommandCompletion {
    let futureResult: EventLoopFuture<String>

    private var promise: EventLoopPromise<String>?

    var isCompleted: Bool { promise == nil }

    init(eventLoop: EventLoop) {
        let promise = eventLoop.makePromise(of: String.self)
        self.promise = promise
        self.futureResult = promise.futureResult
    }

    func succeed(_ output: String) {
        guard let promise else { return }
        self.promise = nil
        promise.succeed(output)
    }

    func fail(_ error: Error) {
        guard let promise else { return }
        self.promise = nil
        promise.fail(error)
    }
}

/// The terminal evidence required before treating an SSH exec as complete.
///
/// A child channel becoming inactive is not proof that its command finished:
/// the parent TCP/SSH transport also closes every child channel when it dies.
/// OpenSSH sends an `exit-status` request for a normally terminated command,
/// so accepting output without that request turns a dropped connection into a
/// valid (often empty or truncated) session list.
struct SSHExecTerminationPolicy {
    private(set) var exitStatus: Int?
    private(set) var exitSignal: SSHExecExitSignal?

    mutating func recordExitStatus(_ status: Int) {
        exitStatus = status
    }

    mutating func recordExitSignal(name: String, message: String) {
        exitSignal = SSHExecExitSignal(name: name, message: message)
    }

    func resolve(
        stdout: String,
        stderr: String,
        usesGateProtocol: Bool
    ) -> Result<String, Error> {
        if let exitSignal {
            let detail = exitSignal.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return .failure(
                SSHError.commandFailed("Remote command terminated by signal \(exitSignal.name)\(suffix)")
            )
        }

        guard let exitStatus else {
            return .failure(
                SSHError.commandFailed("SSH connection closed before the remote command reported its exit status")
            )
        }

        guard exitStatus == 0 else {
            // Gate refusals deliberately use a non-zero process status and a
            // typed `error:*` stdout line. Preserve that domain error instead
            // of replacing it with a generic process-status message.
            if usesGateProtocol, let gateError = GateError.from(line: stdout) {
                return .failure(gateError)
            }

            let diagnostic = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutDiagnostic = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = diagnostic.isEmpty ? stdoutDiagnostic : diagnostic
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return .failure(
                SSHError.commandFailed("Remote command exited with status \(exitStatus)\(suffix)")
            )
        }

        return .success(stdout)
    }
}

struct SSHExecExitSignal {
    let name: String
    let message: String
}

/// Handles a one-shot SSH exec channel: sends exec request on channelActive,
/// collects stdout, and resolves only after a confirmed remote exit status.
private final class ExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let usesGateProtocol: Bool
    private let completion: SSHCommandCompletion
    private var buffer = Data()
    private var stderrBuffer = Data()
    private var termination = SSHExecTerminationPolicy()

    init(
        command: String,
        usesGateProtocol: Bool,
        completion: SSHCommandCompletion
    ) {
        self.command = command
        self.usesGateProtocol = usesGateProtocol
        self.completion = completion
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        context.triggerUserOutboundEvent(execRequest, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelFailureEvent:
            completion.fail(SSHError.commandFailed("Server rejected exec request for: \(command)"))
            context.close(promise: nil)

        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            termination.recordExitStatus(exitStatus.exitStatus)

        case let exitSignal as SSHChannelRequestEvent.ExitSignal:
            termination.recordExitSignal(
                name: exitSignal.signalName,
                message: exitSignal.errorMessage
            )

        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(var buf) = channelData.data else { return }

        if let bytes = buf.readBytes(length: buf.readableBytes) {
            switch channelData.type {
            case .channel:
                buffer.append(contentsOf: bytes)
            case .stdErr:
                stderrBuffer.append(contentsOf: bytes)
            default:
                break
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let output = String(data: buffer, encoding: .utf8) ?? ""
        let standardError = String(data: stderrBuffer, encoding: .utf8) ?? ""
        switch termination.resolve(
            stdout: output,
            stderr: standardError,
            usesGateProtocol: usesGateProtocol
        ) {
        case .success(let output):
            completion.succeed(output)
        case .failure(let error):
            completion.fail(error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        completion.fail(error)
        context.close(promise: nil)
    }
}
