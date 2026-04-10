import Foundation

/// Parses the JSON QR code payload from `handoff pair`.
/// Format: {"v":1,"ip":"100.x.x.x","user":"sagi","key":"<base64>","tmux":"/opt/homebrew/bin/tmux"}
struct QRCodePayload {

    enum ParseError: LocalizedError {
        case invalidJSON
        case unsupportedVersion(Int)
        case missingField(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "QR code does not contain valid pairing data."
            case .unsupportedVersion(let v):
                return "Unsupported pairing version: \(v). Please update Handoff."
            case .missingField(let field):
                return "QR code is missing required field: \(field)."
            }
        }
    }

    static func parse(_ string: String) throws -> ConnectionConfig {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }

        guard let version = json["v"] as? Int else {
            throw ParseError.missingField("v")
        }
        guard version == 1 else {
            throw ParseError.unsupportedVersion(version)
        }

        guard let ip = json["ip"] as? String, !ip.isEmpty else {
            throw ParseError.missingField("ip")
        }
        guard let user = json["user"] as? String, !user.isEmpty else {
            throw ParseError.missingField("user")
        }
        guard let key = json["key"] as? String, !key.isEmpty else {
            throw ParseError.missingField("key")
        }
        guard let tmux = json["tmux"] as? String, !tmux.isEmpty else {
            throw ParseError.missingField("tmux")
        }

        // Validate that the key is valid base64
        guard Data(base64Encoded: key) != nil else {
            throw ParseError.missingField("key (invalid base64)")
        }

        return ConnectionConfig(ip: ip, user: user, privateKey: key, tmuxPath: tmux)
    }
}
