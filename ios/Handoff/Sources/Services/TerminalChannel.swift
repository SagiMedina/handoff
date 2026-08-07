import Foundation
import NIOCore
import NIOSSH

/// Idempotent completion for terminal channel creation. Timeout, cancellation,
/// channel failure, and exec acceptance can converge during reconnect.
private final class TerminalReadyCompletion {
    let futureResult: EventLoopFuture<Void>

    private var promise: EventLoopPromise<Void>?

    init(eventLoop: EventLoop) {
        let promise = eventLoop.makePromise(of: Void.self)
        self.promise = promise
        self.futureResult = promise.futureResult
    }

    var isCompleted: Bool { promise == nil }

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
    private let readyCompletion: TerminalReadyCompletion

    private let closeLock = NSLock()
    private var closeCallback: (() -> Void)?
    private var hasClosed = false
    private var didDeliverClose = false

    /// Called on the NIO event loop with data received from the remote tmux session.
    private var dataCallback: ((Data) -> Void)?
    private var bufferedData: [Data] = []

    /// Called when the remote channel closes (session ended, connection lost).
    var onClosed: (() -> Void)? {
        get {
            closeLock.lock()
            defer { closeLock.unlock() }
            return closeCallback
        }
        set {
            var callbackToDeliver: (() -> Void)?
            closeLock.lock()
            closeCallback = newValue
            if hasClosed, !didDeliverClose, let newValue {
                didDeliverClose = true
                callbackToDeliver = newValue
            }
            closeLock.unlock()
            callbackToDeliver?()
        }
    }

    /// Reference to the child channel for sending data and resize requests.
    private(set) var channel: Channel?

    fileprivate init(
        command: String,
        cols: Int,
        rows: Int,
        readyCompletion: TerminalReadyCompletion
    ) {
        self.command = command
        self.initialCols = cols
        self.initialRows = rows
        self.readyCompletion = readyCompletion
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
            readyCompletion.succeed()
            let data = Data(bytes)
            if let dataCallback {
                dataCallback(data)
            } else {
                // PTY output can arrive immediately after the exec success,
                // before TerminalView resumes from openTerminal() and installs
                // its emulator callback. Preserve every byte in wire order.
                bufferedData.append(data)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        readyCompletion.fail(SSHError.channelError("Channel closed before terminal was ready"))
        notifyClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        readyCompletion.fail(error)
        notifyClosed()
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        readyCompletion.fail(SSHError.channelError("Terminal channel was removed"))
        notifyClosed()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            // Exec request was accepted — terminal is ready
            readyCompletion.succeed()
        } else if event is ChannelFailureEvent {
            readyCompletion.fail(SSHError.commandFailed("Server rejected terminal request"))
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func notifyClosed() {
        var callbackToDeliver: (() -> Void)?
        closeLock.lock()
        hasClosed = true
        if !didDeliverClose, let closeCallback {
            didDeliverClose = true
            callbackToDeliver = closeCallback
        }
        closeLock.unlock()
        callbackToDeliver?()
    }

    /// Install the emulator callback on the channel's event loop, then drain
    /// any output that arrived between exec acceptance and UI wiring. Using
    /// the same event loop as channelRead preserves strict ordering without a
    /// cross-thread lock around potentially expensive terminal parsing.
    func setOnDataReceived(_ callback: @escaping (Data) -> Void) {
        guard let channel else {
            dataCallback = callback
            let pending = bufferedData
            bufferedData.removeAll(keepingCapacity: true)
            pending.forEach(callback)
            return
        }
        channel.eventLoop.execute {
            self.dataCallback = callback
            let pending = self.bufferedData
            self.bufferedData.removeAll(keepingCapacity: true)
            pending.forEach(callback)
        }
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
        guard isConnected,
              let parentChannel = self.parentChannel,
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

        return try await withTaskCancellationHandler {
            try await parentChannel.eventLoop.flatSubmit { () -> EventLoopFuture<TerminalChannelHandler> in
                let readyCompletion = TerminalReadyCompletion(eventLoop: parentChannel.eventLoop)
                let channelPromise = parentChannel.eventLoop.makePromise(of: Channel.self)
                var childChannel: Channel?

                let handler = TerminalChannelHandler(
                    command: command,
                    cols: cols,
                    rows: rows,
                    readyCompletion: readyCompletion
                )

                sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(
                            SSHError.channelError("Unexpected channel type")
                        )
                    }
                    return childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        childChannel.pipeline.addHandler(handler)
                    }
                }

                channelPromise.futureResult.whenSuccess { channel in
                    if readyCompletion.isCompleted {
                        channel.close(promise: nil)
                    } else {
                        childChannel = channel
                    }
                }

                channelPromise.futureResult.whenFailure { error in
                    readyCompletion.fail(error)
                }

                // A zombie parent can leave createChannel pending forever.
                // Bound the attach and close both the child (if created) and
                // parent so Retry starts from a genuinely fresh connection.
                let timeoutTask = parentChannel.eventLoop.scheduleTask(in: .seconds(10)) {
                    readyCompletion.fail(SSHError.commandFailed("Terminal attach timed out"))
                    childChannel?.close(promise: nil)
                    parentChannel.close(promise: nil)
                }
                readyCompletion.futureResult.whenComplete { _ in
                    timeoutTask.cancel()
                }

                return readyCompletion.futureResult.map { handler }
            }.get()
        } onCancel: {
            // Closing the parent also closes a child whose creation promise is
            // still pending, something Swift Task cancellation cannot do to a
            // NIO future by itself.
            parentChannel.close(promise: nil)
        }
    }
}
