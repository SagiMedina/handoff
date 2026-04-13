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
    @State private var tailscaleReady = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !configStore.isPaired {
                    WelcomeView(path: $path)
                } else if !tailscaleReady {
                    TailscaleAuthView(tailscale: tailscale) {
                        tailscaleReady = true
                    }
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
            if !isPaired {
                tailscaleReady = false
            }
        }
        .onAppear {
            // If already paired and Tailscale is already connected (persisted state),
            // skip the auth screen.
            if configStore.isPaired {
                if tailscale.isConnected {
                    tailscaleReady = true
                } else {
                    tailscale.start()
                }
            }
        }
    }
}
