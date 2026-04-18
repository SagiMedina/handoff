import Foundation
import NIOCore
import NIOSSH

/// A long-lived PTY-backed SSH channel for interactive tmux attachment.
/// Bridges SSH I/O with the terminal emulator.
///
/// Flow:
/// 1. channelActive: request PTY → set LANG → exec tmux attach
/// 2. channelRead: forward remote output to onDataReceived callback
/// 3. send(): write terminal input to SSH channel
/// 4. resize(): send window-change request
final class TerminalChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let initialCols: Int
    private let initialRows: Int
    private let readyPromise: EventLoopPromise<Void>
    private var readyPromiseCompleted = false

    /// Called on the NIO event loop with data received from the remote tmux session.
    var onDataReceived: ((Data) -> Void)?

    /// Called when the remote channel closes (session ended, connection lost).
    var onClosed: (() -> Void)?

    /// Reference to the child channel for sending data and resize requests.
    private(set) var channel: Channel?

    init(
        command: String,
        cols: Int,
        rows: Int,
        readyPromise: EventLoopPromise<Void>
    ) {
        self.command = command
        self.initialCols = cols
        self.initialRows = rows
        self.readyPromise = readyPromise
    }

    // MARK: - Channel lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        self.channel = context.channel
    }

    func channelActive(context: ChannelHandlerContext) {
        // 1. Request PTY with xterm-256color (matching Android behavior)
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: initialCols,
            terminalRowHeight: initialRows,
            terminalPixelWidth: initialCols * 8,
            terminalPixelHeight: initialRows * 16,
            terminalModes: .init([:])
        )
        context.triggerUserOutboundEvent(ptyRequest, promise: nil)

        // 2. Set LANG environment variable for Unicode support
        let envRequest = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: false,
            name: "LANG",
            value: "en_US.UTF-8"
        )
        context.triggerUserOutboundEvent(envRequest, promise: nil)

        // 3. Execute the attach command as constructed. We do NOT prepend a
        //    shell `export LANG=…` here — v2 gate commands are parsed as a
        //    whole by the Mac's `handoff gate` forced-command and anything
        //    other than a bare `attach …` would be rejected as
        //    error:unknown_command. v1 callers that need LANG include it
        //    themselves in `command`.
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        context.triggerUserOutboundEvent(execRequest, promise: nil)

        // Do NOT succeed readyPromise here — wait for ChannelSuccessEvent
        // which confirms the exec request was accepted by the server.
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        // Forward both stdout and stderr to the terminal
        guard case .byteBuffer(var buf) = channelData.data else { return }

        if let bytes = buf.readBytes(length: buf.readableBytes) {
            // If we receive data before ChannelSuccessEvent, the exec was implicitly accepted
            if !readyPromiseCompleted {
                readyPromiseCompleted = true
                readyPromise.succeed(())
            }
            onDataReceived?(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !readyPromiseCompleted {
            readyPromiseCompleted = true
            readyPromise.fail(SSHError.channelError("Channel closed before terminal was ready"))
        }
        onClosed?()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !readyPromiseCompleted {
            readyPromiseCompleted = true
            readyPromise.fail(error)
        }
        onClosed?()
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent, !readyPromiseCompleted {
            // Exec request was accepted — terminal is ready
            readyPromiseCompleted = true
            readyPromise.succeed(())
        } else if event is ChannelFailureEvent, !readyPromiseCompleted {
            readyPromiseCompleted = true
            readyPromise.fail(SSHError.commandFailed("Server rejected terminal request"))
        }
        context.fireUserInboundEventTriggered(event)
    }

    // MARK: - Send data to remote

    /// Send terminal input (keystrokes) to the remote tmux session.
    func send(_ data: Data) {
        guard let channel = self.channel else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            channel.writeAndFlush(channelData, promise: nil)
        }
    }

    // MARK: - Resize

    /// Send a window-change request to resize the remote PTY.
    /// Should be debounced by the caller (150ms recommended).
    func resize(cols: Int, rows: Int) {
        guard let channel = self.channel else { return }
        channel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: cols * 8,
                terminalPixelHeight: rows * 16
            )
            channel.triggerUserOutboundEvent(event, promise: nil)
        }
    }
}

// MARK: - SSHManager terminal extension

extension SSHManager {

    /// Open an interactive terminal channel attached to a tmux session.
    /// Returns the TerminalChannelHandler for ongoing I/O and resize.
    ///
    /// CRITICAL: createChannel must be called on the parent channel's event loop.
    func openTerminal(
        tmuxPath: String,
        session: String,
        window: Int,
        cols: Int,
        rows: Int
    ) async throws -> TerminalChannelHandler {
        guard let parentChannel = self.parentChannel,
              let sshHandler = self.sshHandler else {
            throw SSHError.notConnected
        }

        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        // v2: gate handles LANG and tmux attach. The SSH forced-command
        // rejects anything that isn't a bare `attach …`.
        // v1: we still shell raw tmux, with LANG prefix for UTF-8 glyphs
        // (tmux doesn't always inherit it from the non-login SSH env).
        let command: String
        if protocolVersion >= 2 {
            command = "attach \(session) \(window)"
        } else {
            command = "export LANG=en_US.UTF-8; \(tmuxPath) attach -t '\(escaped):\(window)'"
        }

        let handler = try await parentChannel.eventLoop.flatSubmit { () -> EventLoopFuture<TerminalChannelHandler> in
            let readyPromise = parentChannel.eventLoop.makePromise(of: Void.self)
            let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)

            let handler = TerminalChannelHandler(
                command: command,
                cols: cols,
                rows: rows,
                readyPromise: readyPromise
            )

            sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHError.channelError("Unexpected channel type"))
                }
                return childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                    childChannel.pipeline.addHandler(handler)
                }
            }

            channelPromise.futureResult.whenFailure { error in
                readyPromise.fail(error)
            }

            return readyPromise.futureResult.map { handler }
        }.get()

        return handler
    }
}
