import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

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

    /// The active SSH connection's channel, if connected.
    var isConnected: Bool { parentChannel?.isActive ?? false }

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

    /// A fresh UUID per successful `connect()`. Published updates from
    /// in-flight commands compare their captured ID against this one and drop
    /// the write if the connection was torn down or rotated in the meantime —
    /// otherwise a slow `list` response could publish stale permissions over
    /// a later pairing.
    private var connectionID: UUID?

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

        // Stamp this attempt so any in-flight @Published updates that land
        // after a later disconnect/reconnect are dropped on the floor.
        self.connectionID = UUID()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        // Attempt-scoped ID lets us reject any stale trust tap after retry,
        // disconnect, or route changes have abandoned the original handshake.
        let attemptID = UUID()
        await MainActor.run {
            self.currentAttemptID = attemptID
        }

        let privateKey = try parseOpenSSHKey(base64Encoded: config.privateKey)
        let authDelegate = PublicKeyAuthDelegate(
            username: config.user,
            privateKey: privateKey
        )

        // Promise that fires when NIOSSH receives UserAuthSuccessEvent
        let authSuccessPromise = group.next().makePromise(of: Void.self)
        let authWaiter = AuthSuccessHandler(promise: authSuccessPromise)

        let hostKeyValidator = TOFUHostKeyValidator(
            host: config.ip,
            attemptID: attemptID,
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
        self.parentChannel = channel

        // We already hold a reference to the NIOSSHHandler we constructed.
        // Don't query the pipeline — in the SOCKS5 path it isn't installed until
        // PostSOCKSUpgrader runs after the handshake completes. Use our reference
        // directly; once the handler is added to the pipeline, it's the same object.
        self.sshHandler = nioSSHHandler

        // Cap the SSH handshake + auth wait. After iOS backgrounds the app,
        // tsnet's SOCKS5 listener stays bound but WireGuard routing goes
        // silent: TCP connect completes, SOCKS handshake may succeed, yet no
        // SSH packets cross the tunnel. Without this timeout the caller
        // would block indefinitely — we want it to surface as an error that
        // triggers a reconnect. The scheduled task runs on the SSH event
        // loop, same rationale as executeCommand's timeout.
        let authTimeout = channel.eventLoop.scheduleTask(in: .seconds(15)) {
            authSuccessPromise.fail(SSHError.commandFailed("SSH authentication timed out"))
        }
        authSuccessPromise.futureResult.whenComplete { _ in
            authTimeout.cancel()
        }

        // Wait for SSH auth complete (or the scheduled timeout).
        try await authSuccessPromise.futureResult.get()
    }

    // MARK: - Discovery (one-shot exec)

    /// List tmux sessions on the remote Mac. On v2 this goes through the
    /// gate's `list` command (which also emits a `#permissions:` header we
    /// stash on `devicePermissions`). On v1 we still shell raw tmux.
    func listSessions(tmuxPath: String) async throws -> [TmuxSession] {
        let command = protocolVersion >= 2
            ? "list"
            : "\(tmuxPath) list-sessions -F '#{session_name}:#{session_windows}' 2>/dev/null"
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
            let capturedID = self.connectionID
            await MainActor.run { [weak self] in
                guard let self, self.connectionID == capturedID else { return }
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
        let output = try await executeCommand("pair \(deviceName)")
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

    private func invalidatePendingTrust(reason: HostKeyValidationError = .cancelled) {
        let pendingID = pendingTrust?.id
        let promise = pendingTrustPromise
        let eventLoop = pendingTrustEventLoop

        currentAttemptID = nil
        pendingTrustPromise = nil
        pendingTrustEventLoop = nil
        pendingTrustTimeout?.cancel()
        pendingTrustTimeout = nil

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
        guard let parentChannel = self.parentChannel,
              let sshHandler = self.sshHandler else {
            throw SSHError.notConnected
        }

        // iOS tears down the Tailscale SOCKS5 proxy while the app is
        // backgrounded. When the user returns, `parentChannel.isActive` can
        // still read as true even though the underlying socket is zombied —
        // `createChannel` then never fulfills the promise and we hang
        // forever. Cap the per-command wait by scheduling the timeout on the
        // event loop itself (so it fails the promise rather than trying to
        // cancel an `EventLoopFuture.get()` that, by NIO's docs, doesn't
        // honor Task cancellation).
        return try await parentChannel.eventLoop.flatSubmit { () -> EventLoopFuture<String> in
            let resultPromise = parentChannel.eventLoop.makePromise(of: String.self)
            let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)

            // Fail the promise if the command hasn't completed in 10s. The
            // scheduled task runs on the same event loop, so it can touch
            // `resultPromise` safely.
            let timeoutTask = parentChannel.eventLoop.scheduleTask(in: .seconds(10)) {
                resultPromise.fail(SSHError.commandFailed("The request timed out"))
            }
            resultPromise.futureResult.whenComplete { _ in
                timeoutTask.cancel()
            }

            sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHError.channelError("Unexpected channel type"))
                }
                return childChannel.pipeline.addHandler(
                    ExecChannelHandler(command: command, promise: resultPromise)
                )
            }

            channelPromise.futureResult.whenFailure { error in
                resultPromise.fail(error)
            }

            return resultPromise.futureResult
        }.get()
    }

    // MARK: - Disconnect

    func disconnect() {
        invalidatePendingTrust()
        try? parentChannel?.close().wait()
        parentChannel = nil
        sshHandler = nil
        try? group?.syncShutdownGracefully()
        group = nil
        // Reset gate state so a subsequent v1 pairing doesn't inherit stale v2
        // permissions from the prior session. Invalidating the connection ID
        // up-front means any still-in-flight @Published update from the last
        // connection will fail its guard check and be dropped.
        protocolVersion = 1
        connectionID = nil
        Task { @MainActor [weak self] in
            self?.devicePermissions = nil
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

// MARK: - Error types

enum SSHError: LocalizedError {
    case notConnected
    case invalidKey(String)
    case commandFailed(String)
    case channelError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Mac. Check Tailscale."
        case .invalidKey(let reason):
            return "Invalid SSH key: \(reason)"
        case .commandFailed(let reason):
            return "Command failed: \(reason)"
        case .channelError(let reason):
            return "SSH channel error: \(reason)"
        }
    }
}

// MARK: - Auth delegates

/// Public key authentication using Ed25519.
private final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let privateKey: Curve25519.Signing.PrivateKey

    init(username: String, privateKey: Curve25519.Signing.PrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
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

/// Catches UserAuthSuccessEvent from NIOSSH and fulfills a promise.
/// Added to the parent channel pipeline so connect() can wait for auth before returning.
///
/// Promise completion is funneled through handlerRemoved() which NIO guarantees
/// is called exactly once for any handler added to a pipeline. This prevents the
/// EventLoopFuture.deinit assertion that fires if a promise is dropped unfulfilled.
private final class AuthSuccessHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private var promise: EventLoopPromise<Void>?
    private var lastError: Error?

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, let p = promise {
            promise = nil
            p.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lastError = error
        context.fireErrorCaught(error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Safety net: if the handler is torn down and the promise was never fulfilled,
        // fail it so EventLoopFuture.deinit doesn't trap.
        if let p = promise {
            promise = nil
            p.fail(lastError ?? SSHError.channelError("Connection closed before authentication"))
        }
    }
}

// MARK: - Exec channel handler

/// Handles a one-shot SSH exec channel: sends exec request on channelActive,
/// collects stdout, and resolves the promise on channel close.
private final class ExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let promise: EventLoopPromise<String>
    private var buffer = Data()
    private var promiseCompleted = false

    init(command: String, promise: EventLoopPromise<String>) {
        self.command = command
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        context.triggerUserOutboundEvent(execRequest, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelFailureEvent, !promiseCompleted {
            promiseCompleted = true
            promise.fail(SSHError.commandFailed("Server rejected exec request for: \(command)"))
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        // Only collect stdout (type .channel), ignore stderr (type .stdErr)
        guard case .byteBuffer(var buf) = channelData.data,
              channelData.type == .channel else { return }

        if let bytes = buf.readBytes(length: buf.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !promiseCompleted {
            promiseCompleted = true
            let output = String(data: buffer, encoding: .utf8) ?? ""
            promise.succeed(output)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !promiseCompleted {
            promiseCompleted = true
            promise.fail(error)
        }
        context.close(promise: nil)
    }
}
