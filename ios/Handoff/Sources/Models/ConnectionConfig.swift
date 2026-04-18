import Foundation

/// Connection configuration received from QR code pairing.
///
/// Two wire formats are supported:
/// - v1: `{"v":1,"ip":"...","user":"...","key":"<base64 PEM>","tmux":"..."}`
/// - v2: `{"v":2,"i":"...","u":"...","k":"<PEM inner>","t":"...","n":"<hex nonce>"}`
///
/// `privateKey` is always the base64 of the full OpenSSH PEM file, regardless of
/// wire format — QR v2 strips PEM headers to shrink the code and we reconstruct
/// them during parse. `protocolVersion` drives behavior at the SSH layer: v1
/// speaks raw tmux, v2 speaks the `handoff gate` protocol with per-device
/// permissions, pending-device verification, and typed gate errors.
struct ConnectionConfig: Codable, Equatable {
    let ip: String
    let user: String
    let privateKey: String
    let tmuxPath: String
    var protocolVersion: Int = 1
    var nonce: String = ""
}
