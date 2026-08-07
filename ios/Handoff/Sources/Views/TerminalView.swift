import SwiftUI
import SwiftTerm
import UIKit

extension Notification.Name {
    /// Process-local delivery after the store has removed the exact terminal
    /// generation whose channel died. The UUID is carried as `object`.
    static let handoffTerminalChannelClosed = Notification.Name(
        "dev.omriariav.handoff.terminalChannelClosed"
    )
}

/// Separates terminal-generated protocol replies from user input. SwiftTerm's
/// base implementation forwards both through TerminalViewDelegate, which makes
/// client-side read-only enforcement impossible. Protocol replies must always
/// reach the PTY so DA/DSR and focus queries keep working; keyboard, paste, and
/// gesture input remain subject to the presentation's access mode.
final class RemoteSwiftTermView: SwiftTerm.TerminalView {
    var onProtocolReply: ((Data) -> Void)?

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        onProtocolReply?(Data(data))
    }
}

enum TerminalUserInputPolicy {
    static func shouldForward(isInputEnabled: Bool) -> Bool {
        isInputEnabled
    }
}

/// Terminal screen: wraps SwiftTerm for tmux session display with SSH backing.
/// Uses TerminalSessionStore so navigating back and returning preserves
/// the SSH connection and SwiftTerm buffer state.
struct TerminalView: View {
    private static let initialTerminalColumns = 80
    private static let initialTerminalRows = 24

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
    @State private var screenVisibilityID = UUID()
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
        private var epoch = TerminalConnectEpoch()

        var hasInFlightAttempt: Bool {
            inFlight != nil
        }

        /// Claims a new presentation generation before any async SSH work is
        /// started. Swift Task cancellation alone cannot revoke ownership of
        /// an NIO future that resumes later.
        func beginAttempt() -> UInt64 {
            inFlight?.cancel()
            inFlight = nil
            return epoch.begin()
        }

        func owns(_ token: UInt64) -> Bool {
            epoch.owns(token)
        }

        func install(_ task: Task<Void, Never>, for token: UInt64) {
            guard owns(token) else {
                task.cancel()
                return
            }
            inFlight = task
        }

        func finish(_ token: UInt64) {
            guard owns(token) else { return }
            inFlight = nil
        }

        func cancelInFlight() {
            epoch.invalidate()
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

                    if !readOnly {
                        MobileToolbar(
                            modifiers: modifiers,
                            applicationCursorMode: {
                                terminal.terminalView.getTerminal().applicationCursor
                            },
                            onKey: { keyData in
                                let bytes = Array(keyData)
                                terminal.terminalView.send(data: bytes[...])
                            },
                            onPaste: {
                                // SwiftTerm wraps this in bracketed-paste markers when
                                // requested by the remote application.
                                terminal.terminalView.paste(nil)
                            },
                            onDismissKeyboard: {
                                _ = terminal.terminalView.resignFirstResponder()
                            }
                        )
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
            TerminalSessionStore.shared.terminalScreenDidAppear(screenVisibilityID)
            // Reuse existing terminal only if its SSH is still alive.
            // Stale connections (idle timeout, brief iOS suspend) need fresh reconnect.
            if let existing = TerminalSessionStore.shared.get(key),
               existing.sshManager.isConnected,
               existing.accessMode.isCompatible(withReadOnly: readOnly) {
                bindChannelClosure(for: existing)
                activeTerminal = existing
                isConnecting = false
            } else {
                // Drop stale transports and attachments opened under a
                // different permission mode. Reattaching through the gate is
                // what applies a Mac-side read-only downgrade (tmux -r).
                TerminalSessionStore.shared.close(key)
                connectAndAttach()
            }
        }
        .onDisappear {
            // Keep the transport + SwiftTerm buffer cached, but restore the
            // normal device idle timer as soon as the terminal is not visible.
            TerminalSessionStore.shared.terminalScreenDidDisappear(screenVisibilityID)

            let retainedTerminalWasEstablished = activeTerminal.map { presented in
                TerminalSessionStore.shared.get(key)?.id == presented.id
            } ?? false
            if TerminalConnectDisappearPolicy.shouldCancelAttempt(
                hasInFlightAttempt: connectState.hasInFlightAttempt,
                hasActiveRetainedTerminal: retainedTerminalWasEstablished
            ) {
                // A navigation pop can dismiss the view while the SSH/NIO
                // future is still running. Revoke its generation and close its
                // transport so it cannot later register over the terminal the
                // user opens from the Sessions screen.
                connectState.cancelInFlight()
                connectSSHManager.disconnect()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .handoffTerminalChannelClosed)
        ) { notification in
            guard let closedObject = notification.object as? NSUUID else { return }
            let closedTerminalID = closedObject as UUID
            guard TerminalPresentationLifecycle.shouldSurfaceChannelClosure(
                removedCurrentGeneration: true,
                screenIsVisible: TerminalSessionStore.shared.isTerminalScreenVisible(
                    screenVisibilityID
                ),
                presentedTerminalID: activeTerminal?.id,
                closedTerminalID: closedTerminalID
            ) else { return }

            activeTerminal = nil
            isConnecting = false
            errorMessage = TerminalPresentationLifecycle.channelClosedMessage
        }
        .onChange(of: scenePhase) { _, newPhase in
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
        .onChange(of: configStore.terminalFontSize) {
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
        let attempt = connectState.beginAttempt()
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
                guard connectState.owns(attempt) else { return }

                let handler = try await connectSSHManager.openTerminal(
                    tmuxPath: config.tmuxPath,
                    session: sessionName,
                    window: windowIndex,
                    cols: Self.initialTerminalColumns,
                    rows: Self.initialTerminalRows
                )
                try Task.checkCancellation()
                guard connectState.owns(attempt) else {
                    handler.channel?.close(promise: nil)
                    return
                }

                // Create SwiftTerm view once per connection, keep it alive via the store
                let termView = RemoteSwiftTermView(frame: .zero)
                configureTerminalView(termView)
                // Match the local emulator grid to the PTY before any remote data is fed.
                // Layout-driven resizes can take over once the view is on screen.
                termView.resize(
                    cols: Self.initialTerminalColumns,
                    rows: Self.initialTerminalRows
                )

                let terminal = TerminalSessionStore.ActiveTerminal(
                    key: key,
                    sshManager: connectSSHManager,
                    handler: handler,
                    accessMode: TerminalAccessMode(readOnly: readOnly),
                    terminalView: termView
                )

                // Terminal-generated DA/DSR/query replies are safe and
                // required even for read-only attachments. They bypass the
                // user-input delegate so that delegate can enforce read-only.
                termView.onProtocolReply = { [weak handler] data in
                    handler?.send(data)
                }

                // Wire SSH data into the terminal
                handler.setOnDataReceived { [weak termView] data in
                    guard let termView else { return }
                    RemoteTerminalOutput.feed(data, into: termView)
                }

                bindChannelClosure(for: terminal)

                guard connectState.owns(attempt) else {
                    handler.channel?.close(promise: nil)
                    return
                }
                TerminalSessionStore.shared.register(terminal)
                guard connectState.owns(attempt) else {
                    TerminalSessionStore.shared.close(key, ifMatching: terminal.id)
                    return
                }
                activeTerminal = terminal
                isConnecting = false
                connectState.finish(attempt)
            } catch is CancellationError {
                // Task was cancelled — superseded by another connect attempt
                connectState.finish(attempt)
                return
            } catch let mismatch as HostKeyMismatchError {
                guard connectState.owns(attempt) else { return }
                hostKeyMismatch = mismatch
                errorMessage = nil
                isConnecting = false
                connectState.finish(attempt)
            } catch {
                guard connectState.owns(attempt) else { return }
                errorMessage = error.localizedDescription
                isConnecting = false
                connectState.finish(attempt)
            }
        }

        connectState.install(task, for: attempt)
    }

    /// This callback owns no TerminalView state. It always removes the exact
    /// retained generation, even while no terminal screen exists, then emits a
    /// process-local event for whichever identity-matching screen is visible.
    /// Rebinding on cached re-entry also replaces callbacks from older builds
    /// or presentation lifetimes without creating a handler/view retain cycle.
    private func bindChannelClosure(for terminal: TerminalSessionStore.ActiveTerminal) {
        let closeKey = terminal.key
        let terminalID = terminal.id
        terminal.handler.onClosed = {
            Task { @MainActor in
                guard TerminalSessionStore.shared.close(
                    closeKey,
                    ifMatching: terminalID
                ) else { return }

                NotificationCenter.default.post(
                    name: .handoffTerminalChannelClosed,
                    object: terminalID as NSUUID
                )
            }
        }
    }

    private func beginForegroundRecovery() {
        connectState.cancelInFlight()
        if activeTerminal != nil {
            TerminalSessionStore.shared.close(key)
            activeTerminal = nil
        }
        errorMessage = nil
        isConnecting = true
        // Reuse the existing Tailscale proxy and reconnect only this terminal's
        // SSH transport. If the proxy is genuinely unavailable, surface that
        // failure rather than turning foregrounding into an implicit sign-out
        // or whole-network restart.
        connectAndAttach()
    }

    private func configureTerminalView(_ termView: SwiftTerm.TerminalView) {
        applyConfiguredFont(to: termView)
        termView.nativeBackgroundColor = UIColor(Theme.background)
        termView.nativeForegroundColor = UIColor(Theme.text)
        termView.caretColor = UIColor(Theme.primary)
        termView.caretTextColor = UIColor(Theme.background)
        termView.caretViewTracksFocus = false
        // Set a deliberate initial style. Remote applications can still replace it
        // later via the normal terminal cursor-style escape sequences.
        termView.getTerminal().setCursorStyle(.steadyBlock)
        // Handoff supplies its own keyboard-safe mobile toolbar below the terminal.
        termView.inputAccessoryView = nil
        // Hand scrolling over to our own one-finger pan (see SwiftTermView).
        // SwiftTerm otherwise turns a one-finger pan into a mouse *drag* whenever
        // the remote app has mouse tracking on (tmux `mouse on`), which tmux reads
        // as a text selection rather than scrollback. Disabling its mouse reporting
        // frees the pan for us and leaves tap-to-focus + long/double/triple-tap
        // selection intact. Cost: taps no longer report as mouse clicks to the
        // remote app — acceptable for a keyboard-driven terminal.
        termView.allowMouseReporting = false
        // Idle timer follows TerminalView visibility, not this cached UIView.
    }

    private func applyConfiguredFontToActiveTerminal() {
        guard let termView = activeTerminal?.terminalView else { return }
        applyConfiguredFont(to: termView)
        termView.setNeedsDisplay()
    }

    private func applyConfiguredFont(to termView: SwiftTerm.TerminalView) {
        let fontSize = CGFloat(configStore.terminalFontSize)
        let bundledFont = UIFont(name: "MesloLGSNFM-Regular", size: fontSize)
#if DEBUG
        assert(bundledFont != nil, "MesloLGS Nerd Font Mono failed to load; verify UIAppFonts in Info.plist")
        if let bundledFont {
            print("Handoff terminal font loaded: \(bundledFont.fontName)")
        }
#endif
        if let font = bundledFont {
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

/// Pure close-event policy used by the SwiftUI presentation. Both the retained
/// generation and visible generation must match before a transport death can
/// replace the terminal with a reconnect state.
enum TerminalPresentationLifecycle {
    static let channelClosedMessage =
        "The terminal connection closed. Tap Reconnect to attach again."

    static func shouldSurfaceChannelClosure(
        removedCurrentGeneration: Bool,
        screenIsVisible: Bool,
        presentedTerminalID: UUID?,
        closedTerminalID: UUID
    ) -> Bool {
        removedCurrentGeneration
            && screenIsVisible
            && presentedTerminalID == closedTerminalID
    }
}

/// Monotonic ownership for TerminalView attachment attempts. This is separate
/// from SSHManager's transport generation: it protects presentation and store
/// state when a cancelled Task resumes with a non-cancellation error.
struct TerminalConnectEpoch {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func owns(_ token: UInt64) -> Bool {
        current == token
    }
}

/// A completed terminal is intentionally retained across Back, matching
/// Android's TerminalSessionHolder. Only a still-pending attach is disposable
/// with the presentation that started it.
enum TerminalConnectDisappearPolicy {
    static func shouldCancelAttempt(
        hasInFlightAttempt: Bool,
        hasActiveRetainedTerminal: Bool
    ) -> Bool {
        hasInFlightAttempt && !hasActiveRetainedTerminal
    }
}

// MARK: - SwiftTerm UIViewRepresentable

/// Routes PTY output through SwiftTerm's view-level feed lifecycle on the main
/// thread. SwiftTerm's parser can synchronously add/remove its UIKit caret for
/// cursor-visibility escape sequences, despite documenting `feed` as callable
/// from a background thread.
/// Feeding the underlying emulator directly redraws cells but skips
/// `updateCursorPosition`, leaving SwiftTerm's caret view behind after echoed
/// text and backspaces.
enum RemoteTerminalOutput {
    static func feed(_ data: Data, into terminalView: SwiftTerm.TerminalView) {
        let bytes = Array(data)
        let feedView: () -> Void = { [weak terminalView] in
            guard let terminalView else { return }
            terminalView.feed(byteArray: bytes[...])
        }

        if Thread.isMainThread {
            feedView()
        } else {
            // The per-channel NIO callback is serial, and main queue dispatch
            // preserves that chunk order while keeping all UIKit work safe.
            DispatchQueue.main.async(execute: feedView)
        }
    }
}

/// Applies Handoff's one Android-compatible keyboard rewrite without taking
/// ownership of SwiftTerm's broader keyboard/IME encoder. A sticky toolbar
/// Shift followed by Return means LF (Claude multiline) instead of CR.
enum RemoteTerminalInput {
    struct RoutedData: Equatable {
        let data: Data
        let consumedShift: Bool
    }

    static func route(_ data: ArraySlice<UInt8>, stickyShift: Bool) -> RoutedData {
        if stickyShift, data.count == 1, data.first == 0x0D {
            return RoutedData(data: Data([0x0A]), consumedShift: true)
        }
        return RoutedData(data: Data(data), consumedShift: false)
    }
}

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
        context.coordinator.installModifierResetObservers(on: termView)
        termView.controlModifier = isInputEnabled && modifierState.ctrl
        termView.metaModifier = isInputEnabled && modifierState.alt
        if isInputEnabled {
            // Match Android: a writable terminal is keyboard-ready as soon as
            // it is attached, including when a persisted view is re-entered.
            DispatchQueue.main.async { [weak termView] in
                guard let termView, termView.window != nil else { return }
                _ = termView.becomeFirstResponder()
            }
        }
        return termView
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.handler = terminal.handler
        context.coordinator.modifierState = modifierState
        context.coordinator.isInputEnabled = isInputEnabled
        // Ctrl and Alt are native SwiftTerm one-shot modifiers. This lets both
        // software and hardware keyboard input flow through SwiftTerm's own
        // keyboard/IME/Kitty encoders. Sticky Shift is bridged only for Return.
        uiView.controlModifier = isInputEnabled && modifierState.ctrl
        uiView.metaModifier = isInputEnabled && modifierState.alt
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
        private var controlResetObserver: NSObjectProtocol?
        private var metaResetObserver: NSObjectProtocol?

        // One-finger scroll → tmux scrollback. Mirrors Android's Termux `doScroll`:
        // accumulate pixel drag, convert to whole rows by cell height (keeping the
        // sub-row remainder so slow drags aren't rounded away), and emit one
        // scroll-wheel event per row.
        private static let gestureName = "handoffScrollPan"
        private var scrollRemainder: CGFloat = 0
        private var lastTranslationY: CGFloat = 0

        init(
            handler: TerminalChannelHandler,
            modifierState: ModifierState,
            isInputEnabled: Bool
        ) {
            self.handler = handler
            self.modifierState = modifierState
            self.isInputEnabled = isInputEnabled
        }

        deinit {
            if let controlResetObserver {
                NotificationCenter.default.removeObserver(controlResetObserver)
            }
            if let metaResetObserver {
                NotificationCenter.default.removeObserver(metaResetObserver)
            }
        }

        /// SwiftTerm consumes its native one-shot modifiers internally. Mirror
        /// those resets back to the toolbar so highlighted keys never get stuck.
        func installModifierResetObservers(on view: SwiftTerm.TerminalView) {
            if let controlResetObserver {
                NotificationCenter.default.removeObserver(controlResetObserver)
            }
            if let metaResetObserver {
                NotificationCenter.default.removeObserver(metaResetObserver)
            }

            controlResetObserver = NotificationCenter.default.addObserver(
                forName: .terminalViewControlModifierReset,
                object: view,
                queue: .main
            ) { [weak self] _ in
                self?.modifierState.ctrl = false
            }
            metaResetObserver = NotificationCenter.default.addObserver(
                forName: .terminalViewMetaModifierReset,
                object: view,
                queue: .main
            ) { [weak self] _ in
                self?.modifierState.alt = false
            }
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
            guard TerminalUserInputPolicy.shouldForward(isInputEnabled: isInputEnabled) else {
                return
            }
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
            // RemoteSwiftTermView routes terminal-generated protocol replies
            // directly to the PTY. This delegate now represents only user
            // input, so read-only can be enforced without breaking DA/DSR.
            guard TerminalUserInputPolicy.shouldForward(isInputEnabled: isInputEnabled) else {
                return
            }

            let stickyShift = Thread.isMainThread && modifierState.shift
            let routed = RemoteTerminalInput.route(data, stickyShift: stickyShift)
            if routed.consumedShift {
                modifierState.shift = false
            }
            handler.send(routed.data)
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
