import SwiftUI

/// Root navigation: routes based on pairing state + Tailscale connection.
struct ContentView: View {
    @EnvironmentObject var configStore: ConfigStore
    /// Owned at app root in HandoffApp; injected via environmentObject.
    @EnvironmentObject var tailscale: TailscaleManager
    @Environment(\.scenePhase) private var scenePhase

    enum Route: Hashable {
        case scan
        case sessions
        case terminal(session: String, window: Int, readOnly: Bool)
    }

    @State private var path = NavigationPath()
    @State private var hasUnlockedAppFlow = false
    @State private var appLockAvailability = AppLockService.availability()

    /// Derived from `tailscale.state` — Sessions is reachable only while connected.
    /// On `.error` / `.stopped` / `.needsAuth` the user drops back to TailscaleAuthView.
    private var tailscaleReady: Bool {
        tailscale.state == .connected
    }

    private var appLockRequired: Bool {
        configStore.appLockEnabled && appLockAvailability.isAvailable && !hasUnlockedAppFlow
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !configStore.isPaired {
                    WelcomeView(path: $path)
                } else if appLockRequired {
                    AppLockView {
                        hasUnlockedAppFlow = true
                    }
                } else if !tailscaleReady {
                    TailscaleAuthView(tailscale: tailscale)
                } else if configStore.pendingVerification {
                    // v2-only: run the gate pairing handshake before anything
                    // else. VerificationView flips pendingVerification off on
                    // success, re-routing here to SessionsView.
                    VerificationView(tailscale: tailscale)
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
                case .terminal(let session, let window, let readOnly):
                    TerminalView(
                        sessionName: session,
                        windowIndex: window,
                        readOnly: readOnly,
                        tailscale: tailscale
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: configStore.isPaired) { _, isPaired in
            hasUnlockedAppFlow = false
            if isPaired && tailscale.state == .stopped {
                tailscale.start()
            }
        }
        .onChange(of: configStore.appLockEnabled) {
            hasUnlockedAppFlow = false
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                hasUnlockedAppFlow = false
            case .active:
                refreshAppLockAvailability()
                if configStore.isPaired, tailscale.state == .stopped {
                    tailscale.start()
                }
            default:
                break
            }
        }
        .onAppear {
            refreshAppLockAvailability()
            // If already paired but Tailscale isn't running yet, start it.
            // (If it's already connected, the derived gate will route to SessionsView.)
            if configStore.isPaired, tailscale.state == .stopped {
                tailscale.start()
            }
        }
    }

    private func refreshAppLockAvailability() {
        appLockAvailability = AppLockService.availability()
        if !appLockAvailability.isAvailable {
            hasUnlockedAppFlow = true
        }
    }
}
