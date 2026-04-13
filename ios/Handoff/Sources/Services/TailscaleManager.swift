import Foundation
import Gobridge

/// Manages the embedded Tailscale connection via the Go tsnet bridge.
/// Mirrors the Android TailscaleManager.kt — same lifecycle, same Go bridge API.
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

    private let stateDir: String

    init() {
        // Persistent directory for Tailscale node state (survives app restarts)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tsDir = appSupport.appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: tsDir, withIntermediateDirectories: true)
        self.stateDir = tsDir.path
    }

    /// Start the Tailscale connection. Calls back with auth URL if login is needed.
    func start(hostname: String = "handoff-ios") {
        guard state == .stopped || state != .starting else { return }
        state = .starting

        let callback = StatusCallbackImpl { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .authURL(let url):
                    self.state = .needsAuth(url: url)
                case .connected:
                    self.state = .connected
                case .error(let msg):
                    self.state = .error(msg)
                }
            }
        }

        GobridgeStart(stateDir, hostname, callback)
    }

    /// Open a localhost TCP proxy that routes through Tailscale to the target.
    /// Returns the local port number. SSH should connect to 127.0.0.1:<port>.
    func startProxy(targetIP: String, targetPort: Int = 22) throws -> Int {
        var port: Int = 0
        var error: NSError?
        let ok = GobridgeStartProxy(targetIP, targetPort, &port, &error)
        if !ok, let error {
            throw TailscaleError.proxyFailed(error.localizedDescription)
        }
        return port
    }

    /// Stop the Tailscale connection and proxy.
    func stop() {
        GobridgeStop()
        state = .stopped
    }

    /// Reset Tailscale state (delete persisted node keys, force re-auth).
    func resetState() {
        stop()
        try? FileManager.default.removeItem(atPath: stateDir)
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }

    var isConnected: Bool {
        GobridgeIsRunning()
    }
}

// MARK: - Errors

enum TailscaleError: LocalizedError {
    case proxyFailed(String)

    var errorDescription: String? {
        switch self {
        case .proxyFailed(let reason):
            return "Tailscale proxy failed: \(reason)"
        }
    }
}

// MARK: - Go bridge callback

private enum StatusEvent {
    case authURL(String)
    case connected
    case error(String)
}

/// Objective-C class implementing the GobridgeStatusCallback protocol.
/// Go bridge calls these methods from a background goroutine.
private class StatusCallbackImpl: NSObject, GobridgeStatusCallbackProtocol {
    private let handler: (StatusEvent) -> Void

    init(handler: @escaping (StatusEvent) -> Void) {
        self.handler = handler
    }

    func onAuthURL(_ url: String?) {
        guard let url, !url.isEmpty else { return }
        handler(.authURL(url))
    }

    func onConnected() {
        handler(.connected)
    }

    func onError(_ err: String?) {
        handler(.error(err ?? "Unknown Tailscale error"))
    }
}
