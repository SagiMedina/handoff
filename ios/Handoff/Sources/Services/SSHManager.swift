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

    // MARK: - Connect

    /// Establish an SSH connection to the remote Mac.
    /// Waits for both TCP connection AND SSH authentication to complete before returning.
    /// Connect to the remote Mac. If proxyPort > 0, connects to 127.0.0.1:<proxyPort>
    /// instead of config.ip:22 (used when routing through the embedded Tailscale proxy).
    func connect(config: ConnectionConfig, proxyPort: Int = 0) async throws {
        print("[SSH] connect() starting — ip=\(config.ip) user=\(config.user) proxyPort=\(proxyPort)")
        // Tear down any existing connection to prevent resource leaks on retry
        disconnect()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        print("[SSH] parsing OpenSSH key…")
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try parseOpenSSHKey(base64Encoded: config.privateKey)
            print("[SSH] key parsed OK")
        } catch {
            print("[SSH] key parse FAILED: \(error)")
            throw error
        }
        let authDelegate = PublicKeyAuthDelegate(
            username: config.user,
            privateKey: privateKey
        )

        // Promise that fires when NIOSSH receives UserAuthSuccessEvent
        let authSuccessPromise = group.next().makePromise(of: Void.self)
        let authWaiter = AuthSuccessHandler(promise: authSuccessPromise)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: AcceptAllHostKeysDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                    authWaiter
                ])
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(10))

        let connectHost = proxyPort > 0 ? "127.0.0.1" : config.ip
        let connectPort = proxyPort > 0 ? proxyPort : 22
        print("[SSH] TCP connecting to \(connectHost):\(connectPort)…")
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: connectHost, port: connectPort).get()
            print("[SSH] TCP connected, channel active=\(channel.isActive)")
        } catch {
            print("[SSH] TCP connect FAILED: \(error)")
            throw error
        }
        self.parentChannel = channel

        // Get the NIOSSHHandler for creating child channels
        print("[SSH] fetching NIOSSHHandler from pipeline…")
        self.sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        print("[SSH] got NIOSSHHandler, waiting for UserAuthSuccessEvent…")

        // CRITICAL: Wait for UserAuthSuccessEvent before returning.
        // SwiftNIO SSH fires this event on the parent channel when auth completes.
        // Without this wait, createChannel calls will fail with ChannelError.connectPending.
        do {
            try await authSuccessPromise.futureResult.get()
            print("[SSH] auth completed! connect() returning")
        } catch {
            print("[SSH] auth wait FAILED: \(error)")
            throw error
        }
    }

    // MARK: - Discovery (one-shot exec)

    /// List tmux sessions on the remote Mac.
    func listSessions(tmuxPath: String) async throws -> [TmuxSession] {
        print("[SSH] listSessions called with tmuxPath=\(tmuxPath)")
        let output = try await executeCommand("\(tmuxPath) list-sessions -F '#{session_name}:#{session_windows}' 2>/dev/null")
        print("[SSH] listSessions output: \(output.prefix(200))")

        return output
            .split(separator: "\n")
            .compactMap { line -> TmuxSession? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      let windowCount = Int(parts[1]) else { return nil }
                return TmuxSession(
                    name: String(parts[0]),
                    windowCount: windowCount,
                    windows: []
                )
            }
    }

    /// List windows in a tmux session.
    func listWindows(tmuxPath: String, session: String) async throws -> [TmuxWindow] {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        let output = try await executeCommand("\(tmuxPath) list-windows -t '\(escaped)' -F '#{window_index}|#{pane_title}|#{pane_current_command}' 2>/dev/null")

        return output
            .split(separator: "\n")
            .compactMap { line -> TmuxWindow? in
                let parts = line.split(separator: "|", maxSplits: 2)
                guard parts.count == 3,
                      let index = Int(parts[0]) else { return nil }

                let title = String(parts[1]).trimmingCharacters(in: .whitespaces)

                return TmuxWindow(
                    index: index,
                    title: title,
                    command: String(parts[2])
                )
            }
    }

    // MARK: - Session/window management

    /// Create a new tmux session.
    func createSession(tmuxPath: String, name: String) async throws {
        let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await executeCommand("\(tmuxPath) new-session -d -s '\(escaped)'")
    }

    /// Kill an entire tmux session.
    func killSession(tmuxPath: String, name: String) async throws {
        let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await executeCommand("\(tmuxPath) kill-session -t '\(escaped)'")
    }

    /// Kill a single window within a tmux session.
    func killWindow(tmuxPath: String, session: String, windowIndex: Int) async throws {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await executeCommand("\(tmuxPath) kill-window -t '\(escaped):\(windowIndex)'")
    }

    /// Create a new window in a tmux session. Returns the new window's index.
    func createWindow(tmuxPath: String, session: String) async throws -> Int {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        let output = try await executeCommand("\(tmuxPath) new-window -t '\(escaped)' -P -F '#{window_index}'")
        guard let index = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SSHError.commandFailed("Could not parse window index from: \(output)")
        }
        return index
    }

    // MARK: - Execute Command

    /// Execute a one-shot command over SSH and return stdout as a string.
    /// Creates a child session channel, sends exec request, collects output, closes.
    ///
    /// CRITICAL: NIOSSHHandler.createChannel() is not thread-safe — it MUST be called
    /// on the parent channel's event loop. We use flatSubmit to hop onto the right loop.
    /// NIOSSH internally buffers pending channel creations until SSH auth completes.
    private func executeCommand(_ command: String) async throws -> String {
        print("[SSH] executeCommand: \(command.prefix(100))")
        guard let parentChannel = self.parentChannel,
              let sshHandler = self.sshHandler else {
            print("[SSH] executeCommand: NOT CONNECTED")
            throw SSHError.notConnected
        }

        return try await parentChannel.eventLoop.flatSubmit { () -> EventLoopFuture<String> in
            print("[SSH] executeCommand: on event loop, creating child channel")
            let resultPromise = parentChannel.eventLoop.makePromise(of: String.self)
            let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)

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
        try? parentChannel?.close().wait()
        parentChannel = nil
        sshHandler = nil
        try? group?.syncShutdownGracefully()
        group = nil
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
        print("[SSH] AuthHandler event: \(type(of: event))")
        if event is UserAuthSuccessEvent, let p = promise {
            print("[SSH] UserAuthSuccessEvent received — fulfilling promise")
            promise = nil
            p.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SSH] AuthHandler errorCaught: \(error)")
        lastError = error
        context.fireErrorCaught(error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        print("[SSH] AuthHandler removed (promise still pending: \(promise != nil))")
        // Safety net: if the handler is being torn down and the promise
        // was never fulfilled, fail it so EventLoopFuture.deinit doesn't trap.
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
        print("[SSH] ExecChannelHandler channelInactive, buffer size=\(buffer.count)")
        if !promiseCompleted {
            promiseCompleted = true
            let output = String(data: buffer, encoding: .utf8) ?? ""
            promise.succeed(output)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[SSH] ExecChannelHandler errorCaught: \(error)")
        if !promiseCompleted {
            promiseCompleted = true
            promise.fail(error)
        }
        context.close(promise: nil)
    }
}
