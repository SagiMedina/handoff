import Foundation

/// Connection configuration received from QR code pairing.
/// Mirrors the JSON payload: {"v":1,"ip":"...","user":"...","key":"...","tmux":"..."}
struct ConnectionConfig: Codable, Equatable {
    let ip: String
    let user: String
    let privateKey: String  // Base64-encoded Ed25519 private key
    let tmuxPath: String
}
