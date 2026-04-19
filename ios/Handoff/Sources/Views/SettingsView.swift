import SwiftUI

struct SettingsView: View {
    let config: ConnectionConfig
    let readOnly: Bool
    let onDone: () -> Void
    let onSignOutOfTailscale: () -> Void
    let onUnpair: () -> Void

    @EnvironmentObject private var configStore: ConfigStore
    @State private var showSignOutConfirmation = false
    @State private var showUnpairConfirmation = false
    @State private var showResetHostKeyConfirmation = false
    private var appLockAvailability: AppLockAvailability {
        AppLockService.availability()
    }
    private var hasTrustedHostKey: Bool {
        HostKeyStore.shared.hasTrust(for: config.ip)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Security") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(
                                isOn: Binding(
                                    get: { configStore.appLockEnabled },
                                    set: { configStore.setAppLockEnabled($0) }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Require unlock to open app")
                                        .font(.headline)
                                        .foregroundColor(Theme.text)
                                    Text("Use Face ID, Touch ID, or your device passcode before opening Handoff.")
                                        .font(.footnote)
                                        .foregroundColor(Theme.textSecondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .tint(Theme.primary)
                            .disabled(!appLockAvailability.isAvailable)

                            if let message = appLockAvailability.message {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundColor(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .cornerRadius(12)

                        settingsButton(
                            title: "Sign out of Tailscale",
                            subtitle: "Disconnect the embedded tunnel and require sign-in on next launch.",
                            tint: Theme.primary
                        ) {
                            showSignOutConfirmation = true
                        }

                        settingsButton(
                            title: "Unpair this device",
                            subtitle: "Remove the saved Mac pairing and return to the onboarding flow.",
                            tint: Theme.red
                        ) {
                            showUnpairConfirmation = true
                        }

                        if hasTrustedHostKey {
                            settingsButton(
                                title: "Reset trusted SSH key",
                                subtitle: "Forget the stored fingerprint and verify the Mac again on the next SSH connect.",
                                tint: Theme.red
                            ) {
                                showResetHostKeyConfirmation = true
                            }
                        }
                    }

                    section("Terminal") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Text size")
                                    .font(.headline)
                                    .foregroundColor(Theme.text)
                                Spacer()
                                Text("\(configStore.terminalFontSize) pt")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textSecondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(configStore.terminalFontSize) },
                                    set: { configStore.setTerminalFontSize(Int($0.rounded())) }
                                ),
                                in: Double(ConfigStore.minTerminalFontSize)...Double(ConfigStore.maxTerminalFontSize),
                                step: 1
                            )
                            .tint(Theme.primary)

                            Text("Applies to new and existing terminal sessions immediately.")
                                .font(.footnote)
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .cornerRadius(12)
                    }

                    section("Device") {
                        infoRow("Protocol", "v\(config.protocolVersion)")
                        infoRow("Access", readOnly ? "Read-only" : "Read/write")
                        infoRow("Mac IP", config.ip)
                        infoRow("Mac user", config.user)
                    }

                    section("About") {
                        NavigationLink {
                            LicensesView()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Open source licenses")
                                        .font(.headline)
                                        .foregroundColor(Theme.text)
                                    Text("Review the libraries bundled with Handoff for iOS.")
                                        .font(.footnote)
                                        .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onDone()
                    }
                    .foregroundColor(Theme.primary)
                }
            }
            .alert("Sign out of Tailscale?", isPresented: $showSignOutConfirmation) {
                Button("Sign Out", role: .destructive) {
                    onSignOutOfTailscale()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to sign in again on next launch. Your Mac pairing stays intact.")
            }
            .alert("Unpair this device?", isPresented: $showUnpairConfirmation) {
                Button("Unpair", role: .destructive) {
                    onUnpair()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved pairing from the iPhone and returns you to onboarding.")
            }
            .alert("Reset trusted SSH key?", isPresented: $showResetHostKeyConfirmation) {
                Button("Reset", role: .destructive) {
                    HostKeyStore.shared.forget(host: config.ip)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll be prompted to verify the Mac's SSH fingerprint again on the next connection.")
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(Theme.primary)
            content()
        }
    }

    private func settingsButton(title: String, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(tint)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(12)
    }
}
