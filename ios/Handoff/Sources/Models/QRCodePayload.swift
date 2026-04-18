import Foundation

/// Parses the JSON QR code payload emitted by `handoff pair` on the Mac.
///
/// Two payload shapes:
/// - v1 (legacy): `{"v":1,"ip":"...","user":"...","key":"<base64 PEM>","tmux":"..."}`
/// - v2:          `{"v":2,"i":"...","u":"...","k":"<PEM inner>","t":"...","n":"<hex nonce>"}`
///
/// v2 uses compact keys and strips the PEM armor to shrink the encoded QR. We
/// reconstruct the full PEM here and store its base64, so downstream code
/// (`SSHManager.parseOpenSSHKey`) can stay format-agnostic.
struct QRCodePayload {

    enum ParseError: LocalizedError {
        case invalidJSON
        case unsupportedVersion(Int)
        case missingField(String)
        case invalidKey

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "QR code does not contain valid pairing data."
            case .unsupportedVersion(let v):
                return "Unsupported pairing version: \(v). Please update Handoff."
            case .missingField(let field):
                return "QR code is missing required field: \(field)."
            case .invalidKey:
                return "QR code contains an invalid key."
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

        switch version {
        case 1:
            return try parseV1(json)
        case 2:
            return try parseV2(json)
        default:
            throw ParseError.unsupportedVersion(version)
        }
    }

    // MARK: - v1

    private static func parseV1(_ json: [String: Any]) throws -> ConnectionConfig {
        let ip = try required(json, "ip")
        let user = try required(json, "user")
        let key = try required(json, "key")
        let tmux = try required(json, "tmux")

        guard Data(base64Encoded: key) != nil else {
            throw ParseError.invalidKey
        }

        return ConnectionConfig(
            ip: ip,
            user: user,
            privateKey: key,
            tmuxPath: tmux,
            protocolVersion: 1,
            nonce: ""
        )
    }

    // MARK: - v2

    private static func parseV2(_ json: [String: Any]) throws -> ConnectionConfig {
        let ip = try required(json, "i")
        let user = try required(json, "u")
        let innerKey = try required(json, "k")
        let tmux = try required(json, "t")
        let nonce = (json["n"] as? String) ?? ""

        // Validate the inner blob is real OpenSSH key material before we
        // wrap it in armor. The Mac emits raw base64 from the PEM body, so
        // `Data(base64Encoded:)` should decode it; if it doesn't, the QR is
        // corrupt and we reject it now instead of failing later at SSH connect
        // with a less useful error.
        guard Data(base64Encoded: innerKey) != nil else {
            throw ParseError.invalidKey
        }

        // Rebuild PEM from the compact inner blob. The Mac emits the PEM body
        // only (no newlines, no armor); OpenSSH key files need the BEGIN/END
        // lines plus 70-char line wrapping. We then base64 the whole file so
        // downstream parsing is identical to v1.
        let pem = reconstructPEM(innerKey: innerKey)
        guard let pemData = pem.data(using: .utf8) else {
            throw ParseError.invalidKey
        }
        let pemBase64 = pemData.base64EncodedString()

        return ConnectionConfig(
            ip: ip,
            user: user,
            privateKey: pemBase64,
            tmuxPath: tmux,
            protocolVersion: 2,
            nonce: nonce
        )
    }

    private static func reconstructPEM(innerKey: String) -> String {
        let wrapped = innerKey.chunked(into: 70).joined(separator: "\n")
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrapped)
        -----END OPENSSH PRIVATE KEY-----

        """
    }

    private static func required(_ json: [String: Any], _ field: String) throws -> String {
        guard let value = json[field] as? String, !value.isEmpty else {
            throw ParseError.missingField(field)
        }
        return value
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard size > 0, !isEmpty else { return [self] }
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
