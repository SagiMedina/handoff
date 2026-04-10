import SwiftUI
import SwiftTerm

/// Terminal screen: wraps SwiftTerm for tmux session display with SSH backing.
struct TerminalView: View {
    let sessionName: String
    let windowIndex: Int

    @EnvironmentObject var configStore: ConfigStore
    @StateObject private var sshManager = SSHManager()

    @State private var isConnecting = true
    @State private var errorMessage: String?
    @State private var terminalHandler: TerminalChannelHandler?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Theme.primary)
                    Text("Attaching to \(sessionName):\(windowIndex)...")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.red)
                    Text(error)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Retry") {
                        connectAndAttach()
                    }
                    .foregroundColor(Theme.primary)
                }
            } else {
                VStack(spacing: 0) {
                    SwiftTermView(
                        handler: terminalHandler,
                        onResize: { cols, rows in
                            terminalHandler?.resize(cols: cols, rows: rows)
                        }
                    )
                    .ignoresSafeArea(.keyboard)

                    MobileToolbar { keyData in
                        terminalHandler?.send(keyData)
                    }
                }
            }
        }
        .navigationTitle("\(sessionName):\(windowIndex)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            connectAndAttach()
        }
        .onDisappear {
            sshManager.disconnect()
        }
    }

    private func connectAndAttach() {
        guard let config = configStore.config else { return }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await sshManager.connect(config: config)

                // Default terminal size — SwiftTerm will resize once layout is known
                let handler = try await sshManager.openTerminal(
                    tmuxPath: config.tmuxPath,
                    session: sessionName,
                    window: windowIndex,
                    cols: 80,
                    rows: 24
                )

                handler.onClosed = {
                    Task { @MainActor in
                        errorMessage = "Session ended."
                    }
                }

                await MainActor.run {
                    terminalHandler = handler
                    isConnecting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }
}

// MARK: - SwiftTerm UIViewRepresentable

/// Bridges SwiftTerm's TerminalView (UIKit) into SwiftUI.
struct SwiftTermView: UIViewRepresentable {
    let handler: TerminalChannelHandler?
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let termView = SwiftTerm.TerminalView(frame: .zero)

        // Configure appearance
        let fontSize: CGFloat = 14
        if let font = UIFont(name: "JetBrainsMono-Regular", size: fontSize) {
            termView.font = font
        } else {
            termView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        // Dark theme matching Android app
        termView.nativeBackgroundColor = UIColor(Theme.background)
        termView.nativeForegroundColor = UIColor(Theme.text)

        // Keep screen awake while terminal is active
        UIApplication.shared.isIdleTimerDisabled = true

        termView.terminalDelegate = context.coordinator

        return termView
    }

    func updateUIView(_ termView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.handler = handler
        context.coordinator.onResize = onResize

        // Wire SSH data into SwiftTerm
        handler?.onDataReceived = { data in
            DispatchQueue.main.async {
                let terminal = termView.getTerminal()
                data.withUnsafeBytes { rawBuffer in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self)
                    terminal.feed(buffer: bytes)
                }
                termView.setNeedsDisplay()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler, onResize: onResize)
    }

    static func dismantleUIView(_ termView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        var handler: TerminalChannelHandler?
        var onResize: (Int, Int) -> Void
        private var resizeWorkItem: DispatchWorkItem?

        init(handler: TerminalChannelHandler?, onResize: @escaping (Int, Int) -> Void) {
            self.handler = handler
            self.onResize = onResize
        }

        // Terminal sends data (user typed something)
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            handler?.send(Data(data))
        }

        // Terminal resized (layout change, keyboard appeared)
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            // Debounce resize events (150ms) — keyboard animation causes rapid changes
            resizeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.onResize(newCols, newRows)
            }
            resizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        // Required delegate methods
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
    }
}
