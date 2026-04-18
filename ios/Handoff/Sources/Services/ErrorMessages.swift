import Foundation

/// Maps raw errors from the SSH / gate layers to user-facing strings with
/// actionable guidance. Mirrors Android's ErrorMessages.kt so copy and
/// recovery hints stay aligned across platforms.
enum ErrorMessages {

    static func friendlyGate(_ error: GateError) -> String {
        switch error.code {
        case .pending:
            return "Pairing is not yet complete.\nWait for verification on your Mac."
        case .softExpired:
            return "Your access has expired.\nRequest a renewal from the Mac owner."
        case .notFound:
            return "This device is not registered.\nRe-pair from your Mac with `handoff pair`."
        case .readOnly:
            return "This device has read-only access."
        case .denied:
            return "This session is not available on this device."
        case .unknownCommand:
            return "Protocol error.\nYour Mac may need a Handoff update."
        case .failed:
            return "The Mac could not complete that action.\nTry again."
        case .unknown:
            let raw = error.rawCode.replacingOccurrences(of: "error:", with: "")
            return "Access denied: \(raw)"
        }
    }

    /// Umbrella mapper for connection/setup failures where we don't know the
    /// shape of the underlying error. Prefers `GateError` routing where it
    /// applies, falls back to substring matches on `localizedDescription`.
    static func friendlyConnection(_ error: Error) -> String {
        if let gate = error as? GateError { return friendlyGate(gate) }

        let msg = error.localizedDescription.lowercased()
        switch true {
        case msg.contains("auth fail"), msg.contains("auth cancel"), msg.contains("publickey"):
            return "Authentication failed.\nTry re-pairing from your Mac with `handoff pair`."
        case msg.contains("connection refused"):
            return "Mac refused the connection.\nMake sure Remote Login (SSH) is enabled in System Settings → General → Sharing."
        case msg.contains("timeout"), msg.contains("timed out"):
            return "Connection timed out.\nMake sure your Mac is awake and both devices are on Tailscale."
        case msg.contains("no route"), msg.contains("unreachable"):
            return "Can't reach your Mac.\nCheck that both devices are connected to Tailscale."
        case msg.contains("not connected"), msg.contains("channel"):
            return "Disconnected from Mac.\nTap Retry to reconnect."
        default:
            return "Connection error.\nMake sure your Mac is awake and Tailscale is running."
        }
    }

    /// Mapper for per-action failures (create/kill/refresh). Keeps the
    /// verb-specific fallback copy Android uses.
    static func friendlyAction(_ verb: String, _ error: Error) -> String {
        if let gate = error as? GateError { return friendlyGate(gate) }
        let msg = error.localizedDescription.lowercased()
        if msg.contains("not connected") || msg.contains("session is down") {
            return "Lost connection to Mac — tap Refresh to reconnect."
        }
        return "Couldn't \(verb) — tap Refresh to try again."
    }
}
