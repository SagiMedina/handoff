import SwiftUI
import SafariServices

/// Handles Tailscale authentication when the embedded tsnet needs a browser sign-in.
/// Shows a spinner while connecting, a sign-in button when auth is needed,
/// and error states with retry/reset options.
///
/// Auth uses `SFSafariViewController` (in-app system Safari) instead of
/// `UIApplication.shared.open(url)` because the latter backgrounds the app, and
/// iOS kills our process while in background — taking down the embedded tsnet
/// server. SFSafariViewController keeps the app foregrounded AND shares Safari's
/// cookie jar (so the user's existing Tailscale session is reused).
struct TailscaleAuthView: View {
    @ObservedObject var tailscale: TailscaleManager
    @State private var safariURL: URL?

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
                            // Present in-app Safari to keep our process foregrounded.
                            // UIApplication.shared.open(url) would background the app
                            // and iOS would kill our process, taking tsnet down with it.
                            safariURL = authURL
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
                // Briefly visible before ContentView's derived gate switches to SessionsView
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Theme.green)
                    Text("Connected to Tailscale")
                        .foregroundColor(Theme.text)
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
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
        .onChange(of: tailscale.state) { newState in
            // Auto-dismiss the Safari sheet once Tailscale has connected.
            if case .connected = newState, safariURL != nil {
                safariURL = nil
            }
        }
    }
}

/// SwiftUI wrapper around SFSafariViewController.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(Theme.primary)
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// URL needs Identifiable for .sheet(item:)
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
