import Foundation

/// Typed errors returned by the Mac's `handoff gate` forced-command. The wire
/// representation is a single line like `error:pending` or `error:read_only`
/// emitted on stdout before the channel closes.
///
/// Keeping the raw wire string as `rawCode` lets the UI map unfamiliar codes
/// to a generic message without discarding the detail, and lets tests assert
/// on the exact gate response.
struct GateError: Error, LocalizedError, Equatable {
    let rawCode: String

    var code: Code {
        Code(rawValue: rawCode) ?? .unknown
    }

    var errorDescription: String? {
        switch code {
        case .pending:        return "Pairing is not yet complete. Wait for verification on your Mac."
        case .softExpired:    return "Your access has expired. Request a renewal from the Mac owner."
        case .notFound:       return "This device is not registered. Re-pair from your Mac."
        case .readOnly:       return "This device has read-only access."
        case .denied:         return "This session is not available on this device."
        case .unknownCommand: return "Protocol error. Your Mac may need a Handoff update."
        case .failed:         return "The Mac could not complete that action."
        case .unknown:        return "Access denied: \(rawCode.replacingOccurrences(of: "error:", with: ""))"
        }
    }

    enum Code: String {
        case pending        = "error:pending"
        case softExpired    = "error:soft_expired"
        case notFound       = "error:not_found"
        case readOnly       = "error:read_only"
        case denied         = "error:denied"
        case unknownCommand = "error:unknown_command"
        case failed         = "error:failed"
        // Fallback for any wire code we don't recognize. Its raw value is
        // deliberately NOT an `error:` string: every gate response starts with
        // `error:` (see `from(line:)`), so a real server code can never decode
        // straight to `.unknown` — it's only ever reached via the `?? .unknown`
        // fallback in `code`, which preserves the original `rawCode` for display.
        case unknown        = "handoff:unrecognized"
    }

    /// Returns a `GateError` if `line` is a gate error wire format, else nil.
    /// Accepts leading/trailing whitespace but nothing else: a line that happens
    /// to contain "error:" mid-stream is not a gate error.
    static func from(line: String) -> GateError? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("error:") else { return nil }
        return GateError(rawCode: trimmed)
    }
}
