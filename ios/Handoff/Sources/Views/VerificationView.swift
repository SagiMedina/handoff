import SwiftUI
import UIKit

/// Shown after a v2 QR scan while the phone completes the gate pairing
/// handshake with the Mac.
///
/// Flow (mirrors Android's VerificationScreen.kt):
/// 1. Connect SSH over the existing Tailscale loopback proxy.
/// 2. Send `list` first — if it succeeds the device is already active, skip
///    straight to Sessions.
/// 3. If the gate returns `error:pending`, send `pair <deviceName>` and
///    display the returned 6-digit `verify:<code>`.
/// 4. Poll: disconnect + reconnect + `list` every 2s (up to 60s). On success
///    the device is active; on `error:not_found` pairing was rejected; on
///    SSH auth failure the Mac deleted the device (rejected or revoked).
///
/// On success we mark the config as verified and let ContentView route to
/// Sessions. On failure we preserve the pending config so a late Mac approval
/// or transient network problem can be retried without scanning again.
struct VerificationView: View {
    @EnvironmentObject var configStore: ConfigStore
    var tailscale: TailscaleManager

    @StateObject private var sshManager = SSHManager()

    @State private var phase: Phase = .connecting
    @State private var status: String = "Connecting to Mac…"
    @State private var verificationCode: String?
    @State private var errorMessage: String?
    @State private var requiresFreshPairing = false
    @State private var flowTask: Task<Void, Never>?
    @State private var hostKeyMismatch: HostKeyMismatchError?

    private enum Phase: Equatable {
        case connecting
        case awaitingConfirmation
        case failed
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Pairing")
                    .font(.title2).bold()
                    .foregroundColor(Theme.text)

                switch phase {
                case .connecting:
                    connectingView
                case .awaitingConfirmation:
                    awaitingView
                case .failed:
                    failedView
                }
            }
            .padding(32)
        }
        .navigationBarBackButtonHidden(true)
        .sheet(item: $sshManager.pendingTrust) { request in
            HostKeyTrustPromptView(
                request: request,
                onTrust: { sshManager.approveTrust(request) },
                onReject: { sshManager.rejectTrust(request) }
            )
        }
        .fullScreenCover(item: $hostKeyMismatch) { mismatch in
            HostKeyMismatchView(
                error: mismatch,
                onCancel: {
                    hostKeyMismatch = nil
                    errorMessage = mismatch.localizedDescription
                    phase = .failed
                },
                onResetTrust: {
                    sshManager.resetTrust(forHost: mismatch.host)
                    hostKeyMismatch = nil
                    runFlow()
                }
            )
        }
        .onAppear {
            runFlow()
        }
        .onDisappear {
            // Cancelling the flow task *and* disconnecting ensures a mid-poll
            // unpair or route change can't keep reconnecting or call
            // markVerified() against the now-cleared config.
            flowTask?.cancel()
            flowTask = nil
            sshManager.disconnect()
        }
    }

    // MARK: - Subviews

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView().tint(Theme.primary)
            Text(status)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var awaitingView: some View {
        VStack(spacing: 20) {
            Text("Verification Code")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)

            Text(formattedCode)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .kerning(4)
                .foregroundColor(Theme.primary)

            Text("Confirm this code on your Mac.")
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.primary.opacity(0.6))
                Text("Waiting for confirmation…")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary.opacity(0.8))
            }
        }
    }

    private var failedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 40))
                .foregroundColor(Theme.red)
            Text(errorMessage ?? "Pairing failed.")
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if requiresFreshPairing {
                Button("Unpair and scan again") {
                    configStore.unpair()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
            } else {
                Button("Retry") {
                    runFlow()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)

                Button("Unpair and scan again", role: .destructive) {
                    configStore.unpair()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var formattedCode: String {
        guard let code = verificationCode, code.count >= 6 else {
            return verificationCode ?? "------"
        }
        let head = code.prefix(3)
        let tail = code.suffix(3)
        return "\(head) \(tail)"
    }

    // MARK: - Flow

    private func runFlow() {
        guard let config = configStore.config else { return }
        // Cancel any prior flow before starting a new one (defensive: onAppear
        // can fire more than once across view-identity boundaries).
        flowTask?.cancel()
        phase = .connecting
        status = "Connecting to Mac…"
        verificationCode = nil
        errorMessage = nil
        requiresFreshPairing = false
        flowTask = Task {
            do {
                try await verify(config: config)
            } catch is CancellationError {
                // User left the screen or unpaired. Nothing to surface.
                return
            } catch let mismatch as HostKeyMismatchError {
                if Task.isCancelled { return }
                await MainActor.run {
                    hostKeyMismatch = mismatch
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    requiresFreshPairing = error.requiresFreshPairing
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    phase = .failed
                }
            }
        }
    }

    private func verify(config: ConnectionConfig) async throws {
        setStatus("Starting secure connection…")
        guard let proxyConfig = tailscale.proxyConfig else {
            throw VerificationError.noProxy
        }
        let proxy = SSHManager.SOCKSProxy(
            host: proxyConfig.host,
            port: proxyConfig.port,
            username: proxyConfig.username,
            password: proxyConfig.password
        )

        try await sshManager.connect(config: config, proxy: proxy)

        setStatus("Verifying with Mac…")

        // List-first: if the device is already active, skip pairing entirely.
        do {
            _ = try await sshManager.listSessions(tmuxPath: config.tmuxPath)
            try Task.checkCancellation()
            finish()
            return
        } catch let err as GateError where err.code == .pending {
            // Fall through to the pair handshake.
        } catch {
            throw error
        }

        try Task.checkCancellation()
        let deviceName = UIDevice.current.name.isEmpty ? "iPhone" : UIDevice.current.name
        let response = try await sshManager.sendPairCommand(deviceName: deviceName)
        guard response.hasPrefix("verify:") else {
            throw VerificationError.unexpectedResponse(response)
        }
        let code = String(response.dropFirst("verify:".count))
        await MainActor.run {
            verificationCode = code
            phase = .awaitingConfirmation
            status = "Confirm this code on your Mac."
        }

        // Poll up to 60s (30 × 2s) for the Mac operator to accept pairing.
        // Each iteration reconnects because the gate closes the channel after
        // it emits `verify:` — a fresh `list` is how we learn the new status.
        // Cancellation checks bracket every step so an unpair / view-leave
        // aborts the loop instead of mutating state against a dead config.
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try Task.checkCancellation()
            sshManager.disconnect()
            try Task.checkCancellation()
            do {
                try await sshManager.connect(config: config, proxy: proxy)
                try Task.checkCancellation()
                _ = try await sshManager.listSessions(tmuxPath: config.tmuxPath)
                try Task.checkCancellation()
                finish()
                return
            } catch is CancellationError {
                return
            } catch SSHError.authenticationRejected {
                throw VerificationError.credentialsRejected
            } catch let err as GateError {
                switch err.code {
                case .pending:
                    continue
                case .notFound:
                    throw VerificationError.rejectedOnMac
                default:
                    throw err
                }
            } catch {
                // SSH auth failures mean the Mac deleted the device (rejected
                // or revoked). Any other error is transient — swallow and
                // retry within the budget.
                let text = ((error as NSError).userInfo["message"] as? String
                    ?? error.localizedDescription).lowercased()
                if text.contains("auth") || text.contains("publickey") {
                    throw VerificationError.rejectedOnMac
                }
            }
        }
        throw VerificationError.timedOut
    }

    @MainActor
    private func finish() {
        // Final guard: if the task was cancelled between the last check and
        // here, don't flip pendingVerification — the user may have already
        // unpaired or been routed away.
        if Task.isCancelled { return }
        configStore.markVerified()
    }

    @MainActor
    private func setStatus(_ value: String) {
        status = value
    }
}

private enum VerificationError: LocalizedError {
    case noProxy
    case unexpectedResponse(String)
    case credentialsRejected
    case rejectedOnMac
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noProxy:
            return "Tailscale isn't connected. Return and try again."
        case .unexpectedResponse(let raw):
            return "Unexpected response from Mac: \(raw)"
        case .credentialsRejected:
            return "This pairing key is no longer accepted by the Mac. Unpair and scan a new QR code from handoff pair."
        case .rejectedOnMac:
            return "Pairing was rejected on the Mac. Retry if approval may have raced; otherwise unpair and scan a new code."
        case .timedOut:
            return "Pairing timed out. If the Mac approved it late, tap Retry to check again."
        }
    }
}

private extension Error {
    var requiresFreshPairing: Bool {
        if let sshError = self as? SSHError,
           case .authenticationRejected = sshError {
            return true
        }
        if let verificationError = self as? VerificationError {
            switch verificationError {
            case .credentialsRejected, .rejectedOnMac:
                return true
            default:
                break
            }
        }
        return false
    }
}
