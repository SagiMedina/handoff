import SwiftUI

enum AppLockNavigationPolicy {
    enum Event {
        case enteredBackground
        case appLockSettingChanged
        case pairingChanged
        case authenticationSucceeded
    }

    struct Decision: Equatable {
        let hasUnlockedAppFlow: Bool
        let clearsNavigationPath: Bool
    }

    static func decision(
        for event: Event,
        isPaired: Bool,
        appLockEnabled: Bool,
        appLockAvailable: Bool
    ) -> Decision {
        switch event {
        case .authenticationSucceeded:
            return Decision(
                hasUnlockedAppFlow: true,
                clearsNavigationPath: false
            )
        case .pairingChanged:
            // A navigation destination always belongs to the pairing that
            // created it. Never carry it into a new paired/unpaired flow.
            return Decision(
                hasUnlockedAppFlow: false,
                clearsNavigationPath: true
            )
        case .enteredBackground, .appLockSettingChanged:
            let mustLock = isPaired && appLockEnabled && appLockAvailable
            return Decision(
                hasUnlockedAppFlow: false,
                clearsNavigationPath: mustLock
            )
        }
    }
}

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
        configStore.isPaired
            && configStore.appLockEnabled
            && appLockAvailability.isAvailable
            && !hasUnlockedAppFlow
    }

    var body: some View {
        Group {
            if appLockRequired {
                // Keep the lock outside the NavigationStack so no previously
                // pushed destination can render above or around it.
                AppLockView {
                    applyAppLockNavigationEvent(.authenticationSucceeded)
                }
            } else {
                navigationFlow
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: configStore.isPaired) { _, isPaired in
            applyAppLockNavigationEvent(.pairingChanged)
            if isPaired && tailscale.state == .stopped {
                tailscale.start()
            }
        }
        .onChange(of: configStore.appLockEnabled) {
            applyAppLockNavigationEvent(.appLockSettingChanged)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                applyAppLockNavigationEvent(.enteredBackground)
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

    private var navigationFlow: some View {
        NavigationStack(path: $path) {
            Group {
                if !configStore.isPaired {
                    WelcomeView(path: $path)
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
    }

    private func applyAppLockNavigationEvent(_ event: AppLockNavigationPolicy.Event) {
        let decision = AppLockNavigationPolicy.decision(
            for: event,
            isPaired: configStore.isPaired,
            appLockEnabled: configStore.appLockEnabled,
            appLockAvailable: appLockAvailability.isAvailable
        )

        if decision.clearsNavigationPath {
            path = NavigationPath()
        }
        hasUnlockedAppFlow = decision.hasUnlockedAppFlow
    }

    private func refreshAppLockAvailability() {
        appLockAvailability = AppLockService.availability()
        if !appLockAvailability.isAvailable {
            hasUnlockedAppFlow = true
        }
    }
}
