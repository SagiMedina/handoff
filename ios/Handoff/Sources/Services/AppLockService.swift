import Foundation
import LocalAuthentication

enum AppLockAvailability: Equatable {
    case available
    case unavailable(message: String)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var message: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let message):
            return message
        }
    }
}

enum AppLockService {
    static func availability() -> AppLockAvailability {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(message: availabilityMessage(for: error))
        }
        return .available
    }

    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: authenticationError(from: error))
                }
            }
        }
    }

    private static func availabilityMessage(for error: NSError?) -> String {
        guard let error, let code = LAError.Code(rawValue: error.code) else {
            return "Set a device passcode or biometric unlock in Settings to use app lock."
        }

        switch code {
        case .passcodeNotSet:
            return "Set a device passcode to enable app lock."
        case .biometryNotEnrolled:
            return "Enrol Face ID or Touch ID, or set a device passcode, to enable app lock."
        case .biometryNotAvailable:
            return "Biometric unlock is not available on this device."
        case .biometryLockout:
            return "Biometric unlock is locked out. Try again later or use the device passcode."
        default:
            return error.localizedDescription
        }
    }

    private static func authenticationError(from error: Error?) -> Error {
        guard let nsError = error as NSError?,
              let code = LAError.Code(rawValue: nsError.code) else {
            return NSError(
                domain: "AppLockService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unlock failed."]
            )
        }

        switch code {
        case .userCancel, .systemCancel, .appCancel:
            return NSError(
                domain: "AppLockService",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "Authentication canceled."]
            )
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            return NSError(
                domain: "AppLockService",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: availabilityMessage(for: nsError)]
            )
        default:
            return NSError(
                domain: "AppLockService",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: nsError.localizedDescription]
            )
        }
    }
}
