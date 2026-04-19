import SwiftUI
import SwiftTerm
import UIKit

/// Terminal screen: wraps SwiftTerm for tmux session display with SSH backing.
/// Uses TerminalSessionStore so navigating back and returning preserves
/// the SSH connection and SwiftTerm buffer state.
struct TerminalView: View {
    let sessionName: String
    let windowIndex: Int
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
                    SwiftTermView(terminal: terminal)
                        .ignoresSafeArea(.keyboard)

                    MobileToolbar { keyData in
                        terminal.handler.send(keyData)
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

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let termView = terminal.terminalView
        termView.terminalDelegate = context.coordinator
        return termView
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.handler = terminal.handler
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: terminal.handler)
    }

    class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        var handler: TerminalChannelHandler
        private var resizeWorkItem: DispatchWorkItem?

        init(handler: TerminalChannelHandler) {
            self.handler = handler
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            handler.send(Data(data))
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
