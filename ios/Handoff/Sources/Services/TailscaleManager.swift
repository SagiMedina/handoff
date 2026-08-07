import Foundation
import TailscaleKit

/// Manages the embedded Tailscale connection via TailscaleKit (Tailscale's
/// official iOS framework, wrapping libtailscale).
///
/// Replaced the earlier raw gomobile bind of tsnet, which doesn't work on iOS:
/// Apple's sandbox blocks userspace WireGuard from a non-NetworkExtension process.
/// TailscaleKit handles the correct iOS embedding without requiring NE entitlements.
///
/// States: stopped → starting → needsAuth → connected | error.
/// `stopping` is an internal cleanup barrier: no replacement node is opened
/// against the state directory until the previous runtime has fully closed.
@MainActor
final class TailscaleManager: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case stopping
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
        let id: UInt64

        init(node: TailscaleNode, localAPI: LocalAPIClient, processor: MessageProcessor, id: UInt64) {
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

    /// A node is exposed here as soon as it is created, before its IPN bus is
    /// ready. A superseding lifecycle operation can therefore close it to
    /// unblock a cancelled `watchIPNBus` / `up` call before awaiting that task.
    private var startingNode: TailscaleNode?

    /// Convenience accessors keeping existing code happy.
    private var node: TailscaleNode? { runtime?.node }
    private var localAPI: LocalAPIClient? { runtime?.localAPI }
    private var processor: MessageProcessor? { runtime?.processor }

    /// Every lifecycle request invalidates all async work from earlier requests.
    /// This protects runtime, proxy, and public state assignments alike.
    private var lifecycleEpoch = TailscaleLifecycleEpoch()
    private var lifecycleTask: Task<Void, Never>?

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

    /// Bring the Tailscale node up. Re-entry is blocked unless we're stopped or
    /// in error; explicit Retry uses `retry()` below.
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

        schedule(.start, hostname: hostname)
    }

    /// Identity-preserving recovery. This closes the old runtime completely,
    /// then starts a replacement against the same persisted state directory.
    func retry(hostname: String = "handoff-ios") {
        schedule(.retryPreservingIdentity, hostname: hostname)
    }

    /// Compatibility name for existing transport-recovery call sites. A restart
    /// never removes the user's persisted Tailscale identity.
    func restart() {
        retry()
    }

    private func schedule(
        _ operation: TailscaleLifecycleOperation,
        hostname: String = "handoff-ios"
    ) {
        let currentGen = lifecycleEpoch.begin()
        let previousTask = lifecycleTask
        previousTask?.cancel()

        // Transfer ownership of every old node to an uncancelled cleanup task.
        // Closing before awaiting the cancelled start is intentional: close()
        // unblocks libtailscale calls which do not promptly observe Swift task
        // cancellation. A replacement start waits for both cleanup and the old
        // lifecycle task, so two nodes never touch `stateDir` concurrently.
        let oldRuntime = runtime
        runtime = nil
        let oldStartingNode = startingNode
        startingNode = nil
        oldRuntime?.processor.cancel()

        proxyConfig = nil
        state = operation.startsNodeAfterCleanup ? .starting : .stopping

        let cleanupTask = Task { @MainActor in
            if let oldRuntime {
                oldRuntime.processor.cancel()
                try? await oldRuntime.node.close()
            }
            if let oldStartingNode,
               oldRuntime == nil || oldStartingNode !== oldRuntime?.node {
                try? await oldStartingNode.close()
            }
        }

        let task = Task { @MainActor [weak self] in
            await cleanupTask.value
            await previousTask?.value

            guard let self,
                  self.lifecycleEpoch.owns(currentGen),
                  !Task.isCancelled else { return }

            do {
                if operation.deletesPersistedIdentity {
                    if FileManager.default.fileExists(atPath: self.stateDir) {
                        try FileManager.default.removeItem(atPath: self.stateDir)
                    }
                    try FileManager.default.createDirectory(
                        atPath: self.stateDir,
                        withIntermediateDirectories: true
                    )
                }

                guard self.lifecycleEpoch.owns(currentGen),
                      !Task.isCancelled else { return }

                if operation.startsNodeAfterCleanup {
                    await self.startCleanRuntime(hostname: hostname, generation: currentGen)
                } else {
                    self.state = .stopped
                }
            } catch {
                guard self.lifecycleEpoch.owns(currentGen),
                      !Task.isCancelled else { return }
                self.state = .error(error.localizedDescription)
            }

            guard self.lifecycleEpoch.owns(currentGen) else { return }
            self.lifecycleTask = nil
        }
        lifecycleTask = task
    }

    /// Called only after the prior runtime has closed and its lifecycle task has
    /// completed. Every assignment after an async boundary checks `generation`.
    private func startCleanRuntime(hostname: String, generation currentGen: UInt64) async {

        let config = Configuration(
            hostName: hostname,
            path: stateDir,
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: false
        )

        do {
            let node = try TailscaleNode(config: config, logger: logger)
            guard lifecycleEpoch.owns(currentGen), !Task.isCancelled else {
                try? await node.close()
                return
            }
            startingNode = node
            let localAPI = LocalAPIClient(localNode: node, logger: logger)

            let consumer = HandoffIPNConsumer(
                onEvent: { [weak self] notify in
                    Task { @MainActor in
                        guard let self,
                              self.lifecycleEpoch.owns(currentGen) else { return }
                        self.handleNotify(notify)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self,
                              self.lifecycleEpoch.owns(currentGen) else { return }
                        self.state = .error(error.localizedDescription)
                    }
                }
            )

            let processor = try await localAPI.watchIPNBus(
                mask: [.initialState, .prefs, .netmap, .noPrivateKeys, .rateLimitNetmaps],
                consumer: consumer
            )

            guard lifecycleEpoch.owns(currentGen), !Task.isCancelled else {
                processor.cancel()
                // A newer operation took ownership from `startingNode` and is
                // already closing it. Avoid a second concurrent close here.
                if startingNode === node {
                    startingNode = nil
                    try? await node.close()
                }
                return
            }

            startingNode = nil
            runtime = TailscaleRuntime(
                node: node,
                localAPI: localAPI,
                processor: processor,
                id: currentGen
            )

            try await node.up()
            guard lifecycleEpoch.owns(currentGen), !Task.isCancelled else { return }

            // If the bus didn't already give us a BrowseToURL or a .Running state,
            // explicitly trigger interactive login. The bus will deliver BrowseToURL.
            if case .starting = state {
                try? await localAPI.startLoginInteractive()
            }
        } catch {
            guard lifecycleEpoch.owns(currentGen), !Task.isCancelled else { return }

            let failedRuntime: TailscaleRuntime?
            if runtime?.id == currentGen {
                failedRuntime = runtime
                runtime = nil
            } else {
                failedRuntime = nil
            }
            let failedStartingNode = startingNode
            startingNode = nil
            proxyConfig = nil

            // Keep error recovery ordered too: Retry cannot begin until this
            // failed node is fully closed.
            if let failedRuntime {
                failedRuntime.processor.cancel()
                try? await failedRuntime.node.close()
            } else if let failedStartingNode {
                try? await failedStartingNode.close()
            }

            guard lifecycleEpoch.owns(currentGen), !Task.isCancelled else { return }
            state = .error(error.localizedDescription)
        }
    }

    private func handleNotify(_ notify: Ipn.Notify) {
        // ---- Process Notify.State first so it informs the BrowseToURL handling ----
        // tsnet sometimes re-emits a stale BrowseToURL after we connect (a bug, or a
        // re-auth invitation). To distinguish the two: only transition out of
        // .connected when we ALSO see a non-Running State change. A bare BrowseToURL
        // without an accompanying State change is treated as stale and ignored.
        if let s = notify.State {
            switch (state, s) {
            case (.connected, .NeedsLogin), (.connected, .NeedsMachineAuth):
                // Auth lost while connected — drop back to the auth screen.
                proxyConfig = nil
                if let url = notify.BrowseToURL, !url.isEmpty {
                    state = .needsAuth(url: url)
                } else {
                    state = .stopped  // ContentView gate will route to TailscaleAuthView, which calls start() again
                }
                return
            case (.connected, .Stopped), (.connected, .NoState):
                // Node fully stopped — clear runtime, clear proxy, drop to .stopped.
                proxyConfig = nil
                state = .stopped
                return
            default:
                break
            }
        }

        // Pre-connection: route BrowseToURL to needsAuth, errors to .error.
        if let url = notify.BrowseToURL, !url.isEmpty, state != .connected {
            state = .needsAuth(url: url)
        }
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
                let gen = lifecycleEpoch.current
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let lb = try await node.loopback()
                        let parts = lb.address.split(separator: ":")
                        guard parts.count == 2, let port = Int(parts[1]) else {
                            await MainActor.run {
                                guard self.lifecycleEpoch.owns(gen) else { return }
                                self.state = .error("Could not parse Tailscale loopback address: \(lb.address)")
                            }
                            return
                        }
                        await MainActor.run {
                            guard self.lifecycleEpoch.owns(gen) else { return }
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
                            guard self.lifecycleEpoch.owns(gen) else { return }
                            self.state = .error("Tailscale loopback failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Stop / explicit sign-out

    func stop() {
        #if DEBUG
        print("[Tailscale] stop() called, current state=\(state)")
        #endif
        schedule(.stop)
    }

    /// Destructive identity operation. This is deliberately named as a user
    /// action, not as generic recovery: it waits for the old node to close,
    /// then removes the persisted Tailscale identity and requires sign-in.
    func signOutAndForgetIdentity() {
        schedule(.signOutAndForgetIdentity)
    }

}

/// Pure policy kept separate from the Tailscale framework so identity-deletion
/// rules and lifecycle ownership can be unit tested without constructing a node.
enum TailscaleLifecycleOperation: Equatable {
    case start
    case retryPreservingIdentity
    case stop
    case signOutAndForgetIdentity

    var startsNodeAfterCleanup: Bool {
        self == .start || self == .retryPreservingIdentity
    }

    var deletesPersistedIdentity: Bool {
        self == .signOutAndForgetIdentity
    }
}

struct TailscaleLifecycleEpoch {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    func owns(_ token: UInt64) -> Bool {
        current == token
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
