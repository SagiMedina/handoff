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
/// Sessions. On failure we unpair so the user can re-scan cleanly.
struct VerificationView: View {
    @EnvironmentObject var configStore: ConfigStore
    var tailscale: TailscaleManager

    @StateObject private var sshManager = SSHManager()

    @State private var phase: Phase = .connecting
    @State private var status: String = "Connecting to Mac…"
    @State private var verificationCode: String?
    @State private var errorMessage: String?

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
        .onAppear {
            runFlow()
        }
        .onDisappear {
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
            Button("Unpair and try again") {
                configStore.unpair()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primary)
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
        Task {
            do {
                try await verify(config: config)
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    phase = .failed
                }
            }
        }
    }

    private func verify(config: ConnectionConfig) async throws {
        await setStatus("Starting secure connection…")
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

        await setStatus("Verifying with Mac…")

        // List-first: if the device is already active, skip pairing entirely.
        do {
            _ = try await sshManager.listSessions(tmuxPath: config.tmuxPath)
            await finish()
            return
        } catch let err as GateError where err.code == .pending {
            // Fall through to the pair handshake.
        } catch {
            throw error
        }

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
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            sshManager.disconnect()
            do {
                try await sshManager.connect(config: config, proxy: proxy)
                _ = try await sshManager.listSessions(tmuxPath: config.tmuxPath)
                await finish()
                return
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
    case rejectedOnMac
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noProxy:
            return "Tailscale isn't connected. Return and try again."
        case .unexpectedResponse(let raw):
            return "Unexpected response from Mac: \(raw)"
        case .rejectedOnMac:
            return "Pairing was rejected on the Mac. Run `handoff pair` again."
        case .timedOut:
            return "Pairing timed out. Try again from your Mac."
        }
    }
}
