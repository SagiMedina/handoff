import SwiftUI

/// First-launch screen prompting the user to pair with their Mac.
struct WelcomeView: View {
    @EnvironmentObject var configStore: ConfigStore
    @Binding var path: NavigationPath

    #if DEBUG
    @State private var showManualEntry = false
    #endif

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 72))
                .foregroundColor(Theme.primary)

            VStack(spacing: 12) {
                Text("Handoff")
                    .font(.largeTitle.bold())
                    .foregroundColor(Theme.text)

                Text("Continue your Mac terminal\nsessions on your phone.")
                    .font(.body)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 16) {
                Text("On your Mac, run:")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)

                Text("handoff pair")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundColor(Theme.green)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.surface)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    path.append(ContentView.Route.scan)
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.primary)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                #if DEBUG
                Button {
                    showManualEntry = true
                } label: {
                    Label("Debug: Paste QR Payload", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
                #endif
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        #if DEBUG
        .sheet(isPresented: $showManualEntry) {
            DebugPasteView { config in
                configStore.save(config)
                showManualEntry = false
            }
        }
        #endif
    }
}

// MARK: - Debug paste view (only in DEBUG builds)

#if DEBUG
/// Accepts the raw JSON payload from `handoff pair` pasted into a text field.
/// On Mac: run `handoff pair` and copy the JSON line it prints before the QR code.
/// Or use: handoff pair 2>/dev/null | head -1 | pbcopy
struct DebugPasteView: View {
    let onConnect: (ConnectionConfig) -> Void

    @State private var jsonText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Paste the JSON payload from `handoff pair`")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text("Format: {\"v\":1,\"ip\":\"...\",\"user\":\"...\",\"key\":\"...\",\"tmux\":\"...\"}")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                TextEditor(text: $jsonText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .padding(.horizontal)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Button("Paste from Clipboard") {
                    if let clip = UIPasteboard.general.string {
                        jsonText = clip
                    }
                }
                .foregroundColor(.blue)

                Button("Connect") {
                    parseAndConnect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Debug Pairing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func parseAndConnect() {
        errorMessage = nil
        do {
            let config = try QRCodePayload.parse(jsonText.trimmingCharacters(in: .whitespacesAndNewlines))
            onConnect(config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
