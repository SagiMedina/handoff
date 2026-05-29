import SwiftUI
import SwiftTerm
import UIKit

/// Terminal screen: wraps SwiftTerm for tmux session display with SSH backing.
/// Uses TerminalSessionStore so navigating back and returning preserves
/// the SSH connection and SwiftTerm buffer state.
struct TerminalView: View {
    let sessionName: String
    let windowIndex: Int
    let readOnly: Bool
    @ObservedObject var tailscale: TailscaleManager

    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var connectSSHManager = SSHManager()
    @State private var isConnecting = true
    @State private var errorMessage: String?
    @State private var activeTerminal: TerminalSessionStore.ActiveTerminal?
    @State private var hostKeyMismatch: HostKeyMismatchError?
    @State private var wasBackgrounded = false
    @State private var awaitingTransportRecovery = false
    @StateObject private var connectState = ConnectState()
    @StateObject private var modifiers = ModifierState()

    private var key: TerminalSessionStore.Key {
        .init(sessionName: sessionName, windowIndex: windowIndex)
    }

    /// Holds a reference to the in-flight connect Task so repeated triggers
    /// (Reconnect button spam, foreground race) don't start duplicate SSH sessions.
    @MainActor
    private final class ConnectState: ObservableObject {
        var inFlight: Task<Void, Never>?

        func cancelInFlight() {
            inFlight?.cancel()
            inFlight = nil
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Theme.primary)
                    Text(wasBackgrounded ? "Reconnecting..." : "Attaching to \(sessionName):\(windowIndex)...")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
            } else if let error = errorMessage {
                errorStateView(error)
            } else if let terminal = activeTerminal {
                VStack(spacing: 0) {
                    if readOnly {
                        readOnlyBanner
                    }

                    SwiftTermView(
                        terminal: terminal,
                        modifierState: modifiers,
                        isInputEnabled: !readOnly
                    )
                        .ignoresSafeArea(.keyboard)

                    if !readOnly {
                        MobileToolbar(modifiers: modifiers) { keyData in
                            terminal.handler.send(keyData)
                        }
                    }
                }
            }
        }
        .navigationTitle("\(sessionName):\(windowIndex)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $connectSSHManager.pendingTrust) { request in
            HostKeyTrustPromptView(
                request: request,
                onTrust: { connectSSHManager.approveTrust(request) },
                onReject: { connectSSHManager.rejectTrust(request) }
            )
        }
        .fullScreenCover(item: $hostKeyMismatch) { mismatch in
            HostKeyMismatchView(
                error: mismatch,
                onCancel: {
                    hostKeyMismatch = nil
                },
                onResetTrust: {
                    connectSSHManager.resetTrust(forHost: mismatch.host)
                    hostKeyMismatch = nil
                    connectAndAttach()
                }
            )
        }
        .onAppear {
            // Reuse existing terminal only if its SSH is still alive.
            // Stale connections (idle timeout, brief iOS suspend) need fresh reconnect.
            if let existing = TerminalSessionStore.shared.get(key), existing.sshManager.isConnected {
                activeTerminal = existing
                isConnecting = false
            } else {
                // Drop any stale terminal in the store before connecting fresh.
                TerminalSessionStore.shared.close(key)
                connectAndAttach()
            }
        }
        // NOTE: no onDisappear disconnect — the connection persists in the store
        // so navigating back to Sessions preserves terminal state.
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                wasBackgrounded = true
            case .active:
                if wasBackgrounded {
                    wasBackgrounded = false
                    beginForegroundRecovery()
                }
            default:
                break
            }
        }
        .onChange(of: tailscale.state) { newState in
            guard awaitingTransportRecovery else { return }
            switch newState {
            case .connected:
                awaitingTransportRecovery = false
                connectAndAttach()
            case .error(let message):
                awaitingTransportRecovery = false
                isConnecting = false
                errorMessage = message
            default:
                break
            }
        }
        .onChange(of: configStore.terminalFontSize) { _ in
            applyConfiguredFontToActiveTerminal()
        }
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 0) {
            Text("READ-ONLY")
                .foregroundColor(Theme.primary)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1)

            Text("  ·  viewing only, input disabled")
                .foregroundColor(Theme.primary.opacity(0.6))
                .font(.system(size: 11))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Theme.primary.opacity(0.12))
    }

    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(Theme.red)
            Text(error)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 16) {
                Button("Reconnect") {
                    connectAndAttach()
                }
                .foregroundColor(Theme.primary)

                if error.contains("Tailscale") || error.contains("connect") {
                    Button("Open Tailscale") {
                        openTailscale()
                    }
                    .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func connectAndAttach() {
        guard let config = configStore.config else { return }

        // Cancel any in-flight connect attempt before starting a new one.
        // Prevents duplicate SSH sessions from rapid Reconnect taps or
        // foreground/reconnect races.
        connectState.cancelInFlight()
        connectSSHManager.disconnect()

        isConnecting = true
        errorMessage = nil
        hostKeyMismatch = nil

        let task = Task { @MainActor in
            do {
                guard let proxyConfig = tailscale.proxyConfig else {
                    throw TailscaleError.notConnected
                }
                let proxy = SSHManager.SOCKSProxy(
                    host: proxyConfig.host,
                    port: proxyConfig.port,
                    username: proxyConfig.username,
                    password: proxyConfig.password
                )
                try await connectSSHManager.connect(config: config, proxy: proxy)
                try Task.checkCancellation()

                let handler = try await connectSSHManager.openTerminal(
                    tmuxPath: config.tmuxPath,
                    session: sessionName,
                    window: windowIndex,
                    cols: 80,
                    rows: 24
                )
                try Task.checkCancellation()

                // Create SwiftTerm view once per connection, keep it alive via the store
                let termView = SwiftTerm.TerminalView(frame: .zero)
                configureTerminalView(termView)

                let terminal = TerminalSessionStore.ActiveTerminal(
                    key: key,
                    sshManager: connectSSHManager,
                    handler: handler,
                    terminalView: termView
                )

                // Wire SSH data into the terminal
                handler.onDataReceived = { [weak termView] data in
                    DispatchQueue.main.async {
                        guard let termView else { return }
                        let terminal = termView.getTerminal()
                        let array = Array(data)
                        terminal.feed(buffer: array[array.startIndex..<array.endIndex])
                        termView.setNeedsDisplay()
                    }
                }

                let closeKey = key
                handler.onClosed = {
                    Task { @MainActor in
                        TerminalSessionStore.shared.close(closeKey)
                    }
                }

                TerminalSessionStore.shared.register(terminal)
                activeTerminal = terminal
                isConnecting = false
                connectState.inFlight = nil
            } catch is CancellationError {
                // Task was cancelled — superseded by another connect attempt
                return
            } catch let mismatch as HostKeyMismatchError {
                hostKeyMismatch = mismatch
                errorMessage = nil
                isConnecting = false
                connectState.inFlight = nil
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
                connectState.inFlight = nil
            }
        }

        connectState.inFlight = task
    }

    private func beginForegroundRecovery() {
        connectState.cancelInFlight()
        if activeTerminal != nil {
            TerminalSessionStore.shared.close(key)
            activeTerminal = nil
        }
        errorMessage = nil
        isConnecting = true
        // Terminal reconnect failures after background are often lower than SSH:
        // the embedded Tailscale loopback is stale, so opening a fresh SSH
        // session just burns 10s and surfaces "The request timed out". Restart
        // transport first, then reconnect tmux once the proxy is really back.
        awaitingTransportRecovery = true
        tailscale.restart()
    }

    private func configureTerminalView(_ termView: SwiftTerm.TerminalView) {
        applyConfiguredFont(to: termView)
        termView.nativeBackgroundColor = UIColor(Theme.background)
        termView.nativeForegroundColor = UIColor(Theme.text)
        // Hand scrolling over to our own one-finger pan (see SwiftTermView).
        // SwiftTerm otherwise turns a one-finger pan into a mouse *drag* whenever
        // the remote app has mouse tracking on (tmux `mouse on`), which tmux reads
        // as a text selection rather than scrollback. Disabling its mouse reporting
        // frees the pan for us and leaves tap-to-focus + long/double/triple-tap
        // selection intact. Cost: taps no longer report as mouse clicks to the
        // remote app — acceptable for a keyboard-driven terminal.
        termView.allowMouseReporting = false
        // Idle timer is managed centrally by TerminalSessionStore
    }

    private func applyConfiguredFontToActiveTerminal() {
        guard let termView = activeTerminal?.terminalView else { return }
        applyConfiguredFont(to: termView)
        termView.setNeedsDisplay()
    }

    private func applyConfiguredFont(to termView: SwiftTerm.TerminalView) {
        let fontSize = CGFloat(configStore.terminalFontSize)
        if let font = UIFont(name: "JetBrainsMono-Regular", size: fontSize) {
            termView.font = font
        } else {
            termView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    private func openTailscale() {
        if let url = URL(string: "tailscale://") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - SwiftTerm UIViewRepresentable

/// Wraps a persisted SwiftTerm.TerminalView so the underlying buffer survives
/// across SwiftUI view re-creations.
struct SwiftTermView: UIViewRepresentable {
    let terminal: TerminalSessionStore.ActiveTerminal
    @ObservedObject var modifierState: ModifierState
    let isInputEnabled: Bool

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let termView = terminal.terminalView
        termView.terminalDelegate = context.coordinator
        context.coordinator.installScrollGesture(on: termView)
        return termView
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.handler = terminal.handler
        context.coordinator.modifierState = modifierState
        context.coordinator.isInputEnabled = isInputEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            handler: terminal.handler,
            modifierState: modifierState,
            isInputEnabled: isInputEnabled
        )
    }

    class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate, UIGestureRecognizerDelegate {
        var handler: TerminalChannelHandler
        var modifierState: ModifierState
        var isInputEnabled: Bool
        private var resizeWorkItem: DispatchWorkItem?

        // One-finger scroll → tmux scrollback. Mirrors Android's Termux `doScroll`:
        // accumulate pixel drag, convert to whole rows by cell height (keeping the
        // sub-row remainder so slow drags aren't rounded away), and emit one
        // scroll-wheel event per row.
        private static let gestureName = "handoffScrollPan"
        private var scrollRemainder: CGFloat = 0
        private var lastTranslationY: CGFloat = 0

        init(handler: TerminalChannelHandler, modifierState: ModifierState, isInputEnabled: Bool) {
            self.handler = handler
            self.modifierState = modifierState
            self.isInputEnabled = isInputEnabled
        }

        /// Attach (or re-attach, after a view re-creation) the one-finger scroll pan.
        func installScrollGesture(on view: SwiftTerm.TerminalView) {
            // Drop a recognizer left by a previous coordinator so the live one owns scrolling.
            for gesture in view.gestureRecognizers ?? [] where gesture.name == Coordinator.gestureName {
                view.removeGestureRecognizer(gesture)
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            pan.name = Coordinator.gestureName
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SwiftTerm.TerminalView else { return }
            switch gesture.state {
            case .began:
                scrollRemainder = 0
                lastTranslationY = 0
            case .changed:
                let terminal = view.getTerminal()
                let cellHeight = view.bounds.height / CGFloat(max(terminal.rows, 1))
                guard cellHeight > 0 else { return }
                let translationY = gesture.translation(in: view).y
                let incremental = translationY - lastTranslationY
                lastTranslationY = translationY
                let accumulated = scrollRemainder + incremental
                let deltaRows = Int((accumulated / cellHeight).rounded(.towardZero))
                scrollRemainder = accumulated - CGFloat(deltaRows) * cellHeight
                if deltaRows != 0 {
                    doScroll(view: view, terminal: terminal, deltaRows: deltaRows,
                             at: gesture.location(in: view), cellHeight: cellHeight)
                }
            default:
                break
            }
        }

        /// Emit one scroll step per row. Finger moving *down* (positive translation)
        /// reveals older output → wheel up. Branches like Termux's `doScroll`:
        /// tmux/app mouse tracking on → SGR wheel events; bare alternate screen
        /// (e.g. less without mouse) → arrow keys. Normal-buffer scrollback is left
        /// to SwiftTerm's own scroll view.
        private func doScroll(view: SwiftTerm.TerminalView, terminal: Terminal,
                              deltaRows: Int, at point: CGPoint, cellHeight: CGFloat) {
            let up = deltaRows > 0
            let count = min(abs(deltaRows), 40)   // guard against a runaway flick
            let mouseActive = terminal.mouseMode != .off
            let alternate = terminal.isCurrentBufferAlternate
            guard mouseActive || alternate else { return }

            let cellWidth = view.bounds.width / CGFloat(max(terminal.cols, 1))
            let col = cellWidth > 0 ? min(max(Int(point.x / cellWidth) + 1, 1), terminal.cols) : 1
            let row = min(max(Int(point.y / cellHeight) + 1, 1), terminal.rows)

            var bytes: [UInt8] = []
            for _ in 0..<count {
                if mouseActive {
                    // SGR 1006 mouse wheel: button 64 = up, 65 = down.
                    let button = up ? 64 : 65
                    bytes.append(contentsOf: Array("\u{1b}[<\(button);\(col);\(row)M".utf8))
                } else {
                    bytes.append(contentsOf: Array((up ? "\u{1b}[A" : "\u{1b}[B").utf8))
                }
            }
            if !bytes.isEmpty {
                handler.send(Data(bytes))
            }
        }

        // Scroll pan coexists with SwiftTerm's own scroll view / selection gestures.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard isInputEnabled else { return }
            let bytes = TerminalModifierCodec.applyModifiers(
                to: Array(data),
                using: modifierState
            )
            handler.send(Data(bytes))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            resizeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.handler.resize(cols: newCols, rows: newRows)
            }
            resizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
