import SwiftUI

struct AppLockView: View {
    let onUnlocked: () -> Void

    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @State private var authTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundColor(Theme.primary)

                VStack(spacing: 8) {
                    Text("Unlock Handoff")
                        .font(.title2.bold())
                        .foregroundColor(Theme.text)

                    Text("Authenticate to open your paired sessions.")
                        .font(.body)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(Theme.red)
                        .multilineTextAlignment(.center)
                } else if isAuthenticating {
                    ProgressView()
                        .tint(Theme.primary)
                    Text("Waiting for authentication…")
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer()

                Button {
                    startAuthentication()
                } label: {
                    Text(isAuthenticating ? "Unlocking…" : "Unlock")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.primary)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(isAuthenticating)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .padding(32)
        }
        .navigationBarHidden(true)
        .onAppear {
            startAuthentication()
        }
        .onDisappear {
            authTask?.cancel()
            authTask = nil
        }
    }

    private func startAuthentication() {
        guard authTask == nil else { return }

        errorMessage = nil
        isAuthenticating = true
        authTask = Task {
            do {
                try await AppLockService.authenticate(
                    reason: "Unlock Handoff to access your paired sessions."
                )
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    authTask = nil
                    isAuthenticating = false
                    onUnlocked()
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    errorMessage = (error as NSError).localizedDescription
                    isAuthenticating = false
                    authTask = nil
                }
            }
        }
    }
}
