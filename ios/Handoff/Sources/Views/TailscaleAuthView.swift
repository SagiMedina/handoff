import SwiftUI

/// Handles Tailscale authentication when the embedded tsnet needs a browser sign-in.
/// Shows a spinner while connecting, a sign-in button when auth is needed,
/// and error states with retry/reset options.
struct TailscaleAuthView: View {
    @ObservedObject var tailscale: TailscaleManager
    let onConnected: () -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch tailscale.state {
            case .stopped, .starting:
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Theme.primary)
                    Text("Connecting to Tailscale...")
                        .foregroundColor(Theme.textSecondary)
                }
                .onAppear {
                    if tailscale.state == .stopped {
                        tailscale.start()
                    }
                }

            case .needsAuth(let url):
                VStack(spacing: 24) {
                    Image(systemName: "network")
                        .font(.system(size: 56))
                        .foregroundColor(Theme.primary)

                    Text("Sign in to Tailscale")
                        .font(.title2.bold())
                        .foregroundColor(Theme.text)

                    Text("Handoff uses Tailscale for secure networking between your Mac and phone. Sign in once — it's saved for future launches.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button {
                        if let authURL = URL(string: url) {
                            UIApplication.shared.open(authURL)
                        }
                    } label: {
                        Label("Open Browser to Sign In", systemImage: "safari")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 24)

                    Text("Waiting for sign-in...")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)

                    ProgressView()
                        .tint(Theme.textSecondary)
                }

            case .connected:
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.green)
                    Text("Connected to Tailscale")
                        .foregroundColor(Theme.text)
                }
                .onAppear {
                    onConnected()
                }

            case .error(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.red)
                    Text(message)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    HStack(spacing: 16) {
                        Button("Retry") {
                            tailscale.stop()
                            tailscale.start()
                        }
                        .foregroundColor(Theme.primary)

                        Button("Reset") {
                            tailscale.resetState()
                            tailscale.start()
                        }
                        .foregroundColor(Theme.red)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .navigationTitle("Tailscale")
        .navigationBarTitleDisplayMode(.inline)
    }
}
