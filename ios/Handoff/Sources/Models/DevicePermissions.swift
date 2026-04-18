import Foundation

/// Permissions the Mac's `handoff gate` reports for this device on the
/// `#permissions:` line of the `list` response.
///
/// Wire format: `#permissions:read_only=<bool>,sessions=<pattern1>;<pattern2>;...`
///
/// `sessions` is a list of tmux session name patterns (glob-style on the Mac
/// side). A single `"*"` entry means "all sessions". The client uses this to
/// grey-out create/kill affordances (when `readOnly`) and to surface which
/// session scope is in effect.
struct DevicePermissions: Equatable {
    let readOnly: Bool
    let sessions: [String]

    static let unrestricted = DevicePermissions(readOnly: false, sessions: ["*"])

    /// Parses the gate's `#permissions:` header. Unknown keys are ignored so
    /// older clients don't break when new gate metadata lands.
    static func parse(header: String) -> DevicePermissions {
        let body = header.hasPrefix("#permissions:")
            ? String(header.dropFirst("#permissions:".count))
            : header

        var readOnly = false
        var sessions: [String] = ["*"]

        for param in body.split(separator: ",") {
            let kv = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1])
            switch key {
            case "read_only":
                readOnly = (value == "true")
            case "sessions":
                sessions = value.split(separator: ";").map(String.init)
            default:
                break
            }
        }

        return DevicePermissions(readOnly: readOnly, sessions: sessions)
    }
}
