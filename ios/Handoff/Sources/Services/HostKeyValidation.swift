import Foundation
import NIOCore
import NIOSSH
import Crypto

/// SHA256 fingerprint of an SSH host key in OpenSSH's `SHA256:<base64-nopad>`
/// display format so the user can compare it directly on the Mac.
struct HostKeyFingerprint: Equatable, Codable {
    let algorithm: String
    let sha256: String

    static func compute(from key: NIOSSHPublicKey) -> HostKeyFingerprint {
        // NIOSSHPublicKey is NOT CustomStringConvertible, so String(describing:)
        // would yield Swift's reflection dump — not the OpenSSH wire format — and
        // the base64 decode below would fail, producing a fingerprint that never
        // matches `ssh-keygen -lf` on the Mac. String(openSSHPublicKey:) emits
        // "algorithm base64-wire", the exact bytes OpenSSH SHA256-fingerprints.
        let description = String(openSSHPublicKey: key)
        let parts = description.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let algorithm = parts.first.map(String.init) ?? "ssh-unknown"
        let rawData: Data

        if parts.count >= 2, let decoded = Data(base64Encoded: String(parts[1])) {
            rawData = decoded
        } else {
            // Keep the fingerprint stable and non-empty even if NIOSSH changes
            // its textual formatting in a future release.
            rawData = Data(description.utf8)
        }

        let digest = SHA256.hash(data: rawData)
        let base64 = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return HostKeyFingerprint(algorithm: algorithm, sha256: "SHA256:\(base64)")
    }
}

struct HostKeyMismatchError: Error, LocalizedError, Identifiable {
    let host: String
    let stored: HostKeyFingerprint
    let seen: HostKeyFingerprint
    let id: UUID = UUID()

    var errorDescription: String? {
        "Host key for \(host) has changed - connection blocked for safety."
    }
}

enum HostKeyValidationError: Error, LocalizedError {
    case userRejected
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .userRejected:
            return "Host key was not trusted."
        case .timedOut:
            return "Host-key confirmation timed out."
        case .cancelled:
            return "Host-key validation was cancelled."
        }
    }
}

struct PendingTrustRequest: Identifiable, Equatable {
    let id: UUID
    let host: String
    let fingerprint: HostKeyFingerprint
}

final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    typealias FirstTrustBridge = (PendingTrustRequest, EventLoopPromise<Void>) -> Void
    typealias MismatchBridge = (HostKeyMismatchError, EventLoopPromise<Void>) -> Void

    private let host: String
    private let attemptID: UUID
    private let store: HostKeyStore
    private let onFirstTrust: FirstTrustBridge
    private let onMismatch: MismatchBridge

    init(
        host: String,
        attemptID: UUID,
        store: HostKeyStore,
        onFirstTrust: @escaping FirstTrustBridge,
        onMismatch: @escaping MismatchBridge
    ) {
        self.host = host
        self.attemptID = attemptID
        self.store = store
        self.onFirstTrust = onFirstTrust
        self.onMismatch = onMismatch
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let seen = HostKeyFingerprint.compute(from: hostKey)

        if let stored = store.fingerprint(for: host) {
            if stored == seen {
                validationCompletePromise.succeed(())
            } else {
                onMismatch(
                    HostKeyMismatchError(host: host, stored: stored, seen: seen),
                    validationCompletePromise
                )
            }
            return
        }

        onFirstTrust(
            PendingTrustRequest(id: attemptID, host: host, fingerprint: seen),
            validationCompletePromise
        )
    }
}
