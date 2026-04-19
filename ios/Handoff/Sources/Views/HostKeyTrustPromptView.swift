import SwiftUI

struct HostKeyTrustPromptView: View {
    let request: PendingTrustRequest
    let onTrust: () -> Void
    let onReject: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var decided = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.primary)
                    Text("Is this your Mac?")
                        .font(.title3).bold()
                }

                detailBlock(title: "Host", value: request.host)
                detailBlock(title: "Algorithm", value: request.fingerprint.algorithm)
                detailBlock(title: "SHA256 fingerprint", value: request.fingerprint.sha256, footnote: true)

                Text("Compare this with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on your Mac. Only trust it if the fingerprints match.")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        decided = true
                        onTrust()
                        dismiss()
                    } label: {
                        Text("Trust this host")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    Button(role: .cancel) {
                        decided = true
                        onReject()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
            }
            .padding(24)
            .background(Theme.background)
            .navigationTitle("Verify host")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        .onDisappear {
            if !decided {
                onReject()
            }
        }
    }

    private func detailBlock(title: String, value: String, footnote: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(.system(footnote ? .footnote : .body, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(Theme.text)
        }
    }
}
