import SwiftUI

/// Root navigation: routes based on pairing state + Tailscale connection.
struct ContentView: View {
    @EnvironmentObject var configStore: ConfigStore
    @StateObject private var tailscale = TailscaleManager()

    enum Route: Hashable {
        case scan
        case sessions
        case terminal(session: String, window: Int)
    }

    @State private var path = NavigationPath()

    /// Derived from `tailscale.state` — Sessions is reachable only while connected.
    /// On `.error` / `.stopped` / `.needsAuth` the user drops back to TailscaleAuthView.
    private var tailscaleReady: Bool {
        tailscale.state == .connected
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !configStore.isPaired {
                    WelcomeView(path: $path)
                } else if !tailscaleReady {
                    TailscaleAuthView(tailscale: tailscale)
                } else {
                    SessionsView(path: $path, tailscale: tailscale)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .scan:
                    ScanView(path: $path)
                case .sessions:
                    SessionsView(path: $path, tailscale: tailscale)
                case .terminal(let session, let window):
                    TerminalView(sessionName: session, windowIndex: window, tailscale: tailscale)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: configStore.isPaired) { isPaired in
            if isPaired && tailscale.state == .stopped {
                tailscale.start()
            }
        }
        .onAppear {
            // If already paired but Tailscale isn't running yet, start it.
            // (If it's already connected, the derived gate will route to SessionsView.)
            if configStore.isPaired, tailscale.state == .stopped {
                tailscale.start()
            }
        }
    }
}
