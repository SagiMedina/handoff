import Foundation
import TailscaleKit

/// Manages the embedded Tailscale connection via TailscaleKit (Tailscale's
/// official iOS framework, wrapping libtailscale).
///
/// Replaced the earlier raw gomobile bind of tsnet, which doesn't work on iOS:
/// Apple's sandbox blocks userspace WireGuard from a non-NetworkExtension process.
/// TailscaleKit handles the correct iOS embedding without requiring NE entitlements.
///
/// States: stopped → starting → needsAuth → connected | error
@MainActor
final class TailscaleManager: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case needsAuth(url: String)
        case connected
        case error(String)
    }

    @Published private(set) var state: State = .stopped

    /// SOCKS5 proxy info for routing TCP through Tailscale. Available once `state == .connected`.
    struct ProxyConfig: Equatable {
        let host: String
        let port: Int
        let username: String
        let password: String
    }
    @Published private(set) var proxyConfig: ProxyConfig?

    private let stateDir: String
    private let logger = HandoffLogger()

    /// One reference-type box holding all the runtime pieces. Per codex:
    /// "collapse `node + localAPI + processor` into one runtime box with deinit logs".
    /// If this object's deinit fires, tailscale_close() runs and the SOCKS5/LocalAPI
    /// servers die. Useful for diagnosing ARC ownership issues.
    private final class TailscaleRuntime {
        let node: TailscaleNode
        let localAPI: LocalAPIClient
        let processor: MessageProcessor
        let id: Int

        init(node: TailscaleNode, localAPI: LocalAPIClient, processor: MessageProcessor, id: Int) {
            self.node = node
            self.localAPI = localAPI
            self.processor = processor
            self.id = id
            #if DEBUG
            print("[Tailscale] runtime[\(id)] init")
            #endif
        }

        deinit {
            #if DEBUG
            print("[Tailscale] runtime[\(id)] deinit — tailscale_close will fire")
            #endif
        }
    }

    private var runtime: TailscaleRuntime?

    /// Convenience accessors keeping existing code happy.
    private var node: TailscaleNode? { runtime?.node }
    private var localAPI: LocalAPIClient? { runtime?.localAPI }
    private var processor: MessageProcessor? { runtime?.processor }

    /// Generation counter — bumped on every start()/stop(). Bus events from a
    /// previous generation are ignored so stale notifications can't clobber state.
    private var generation: Int = 0

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tsDir = appSupport.appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: tsDir, withIntermediateDirectories: true)
        self.stateDir = tsDir.path
        #if DEBUG
        print("[Tailscale] manager init \(ObjectIdentifier(self))")
        #endif
    }

    deinit {
        #if DEBUG
        print("[Tailscale] manager deinit \(ObjectIdentifier(self))")
        #endif
    }

    var isConnected: Bool { state == .connected }

    // MARK: - Start

    /// Bring the Tailscale node up. Re-entry blocked unless we're stopped or in error.
    func start(hostname: String = "handoff-ios") {
        #if DEBUG
        print("[Tailscale] start() called, current state=\(state)")
        #endif
        switch state {
        case .stopped, .error:
            break
        default:
            #if DEBUG
            print("[Tailscale] start() — re-entry blocked, state=\(state)")
            #endif
            return
        }

        generation += 1
        let currentGen = generation
        state = .starting

        let config = Configuration(
            hostName: hostname,
            path: stateDir,
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: false
        )

        Task {
            do {
                let node = try TailscaleNode(config: config, logger: logger)
                let localAPI = LocalAPIClient(localNode: node, logger: logger)

                let consumer = HandoffIPNConsumer(
                    onEvent: { [weak self] notify in
                        Task { @MainActor in
                            guard let self, self.generation == currentGen else { return }
                            self.handleNotify(notify)
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.generation == currentGen else { return }
                            self.state = .error(error.localizedDescription)
                        }
                    }
                )

                let processor = try await localAPI.watchIPNBus(
                    mask: [.initialState, .prefs, .netmap, .noPrivateKeys, .rateLimitNetmaps],
                    consumer: consumer
                )

                self.runtime = TailscaleRuntime(
                    node: node,
                    localAPI: localAPI,
                    processor: processor,
                    id: currentGen
                )

                try await node.up()

                // If the bus didn't already give us a BrowseToURL or a .Running state,
                // explicitly trigger interactive login. The bus will deliver BrowseToURL.
                if case .starting = state {
                    try? await localAPI.startLoginInteractive()
                }
            } catch {
                guard self.generation == currentGen else { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func handleNotify(_ notify: Ipn.Notify) {
        // Only transition to .needsAuth if we're NOT already connected.
        // tsnet emits stale BrowseToURL events even after connection — bouncing
        // back to the auth screen on those breaks the connected experience.
        if let url = notify.BrowseToURL, !url.isEmpty, state != .connected {
            state = .needsAuth(url: url)
        }
        // Same logic for errors — once connected, transient bus errors shouldn't
        // tear down the UI. Only treat errors as fatal during connection setup.
        if let err = notify.ErrMessage, !err.isEmpty, state != .connected {
            state = .error(err)
        }
        if let s = notify.State, s == .Running {
            #if DEBUG
            print("[Tailscale] notify.State == .Running — fetching loopback")
            #endif
            // Fetch loopback config first, then transition to .connected.
            // Doing it in this order means by the time SessionsView reacts to
            // .connected, proxyConfig is already populated for SOCKS5.
            if let node = self.node {
                let gen = generation
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let lb = try await node.loopback()
                        let parts = lb.address.split(separator: ":")
                        guard parts.count == 2, let port = Int(parts[1]) else {
                            await MainActor.run {
                                guard self.generation == gen else { return }
                                self.state = .error("Could not parse Tailscale loopback address: \(lb.address)")
                            }
                            return
                        }
                        await MainActor.run {
                            guard self.generation == gen else { return }
                            self.proxyConfig = ProxyConfig(
                                host: String(parts[0]),
                                port: port,
                                username: "tsnet",
                                password: lb.proxyCredential
                            )
                            #if DEBUG
                            print("[Tailscale] -> .connected (proxyConfig ready: \(parts[0]):\(port))")
                            #endif
                            self.state = .connected
                        }
                    } catch {
                        await MainActor.run {
                            guard self.generation == gen else { return }
                            self.state = .error("Tailscale loopback failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Stop / reset

    func stop() {
        #if DEBUG
        print("[Tailscale] stop() called, current state=\(state)")
        #endif
        generation += 1
        let oldRuntime = runtime
        runtime = nil
        proxyConfig = nil
        state = .stopped

        Task {
            await oldRuntime?.processor.cancel()
            try? await oldRuntime?.node.close()
        }
    }

    /// Hard reset — close node and delete the state dir to force re-auth on next start.
    func resetState() {
        stop()
        try? FileManager.default.removeItem(atPath: stateDir)
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }
}

// MARK: - Errors

enum TailscaleError: LocalizedError {
    case notConnected
    case loopbackUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Tailscale not connected."
        case .loopbackUnavailable:
            return "Tailscale loopback proxy unavailable."
        }
    }
}

// MARK: - IPN bus consumer

private actor HandoffIPNConsumer: MessageConsumer {
    private let onEvent: @Sendable (Ipn.Notify) -> Void
    private let onError: @Sendable (Error) -> Void

    init(
        onEvent: @escaping @Sendable (Ipn.Notify) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.onEvent = onEvent
        self.onError = onError
    }

    func notify(_ notify: Ipn.Notify) {
        onEvent(notify)
    }

    func error(_ error: any Error) {
        onError(error)
    }
}

// MARK: - Logger

private struct HandoffLogger: LogSink {
    var logFileHandle: Int32? { nil }

    func log(_ message: String) {
        #if DEBUG
        print("[Tailscale] \(message)")
        #endif
    }
}
