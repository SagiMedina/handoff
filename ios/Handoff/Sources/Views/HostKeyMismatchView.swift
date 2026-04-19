import SwiftUI

struct HostKeyMismatchView: View {
    let error: HostKeyMismatchError
    let onCancel: () -> Void
    let onResetTrust: () -> Void

    @State private var confirmingReset = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.red)
                        Text("Possible man-in-the-middle")
                            .font(.headline)
                            .foregroundColor(Theme.red)
                    }

                    Text("Host key changed")
                        .font(.title2).bold()
                        .foregroundColor(Theme.red)

                    Text("The SSH fingerprint for \(error.host) doesn't match what you trusted previously. This could mean the Mac was reinstalled, or that something is intercepting your connection.")
                        .foregroundColor(Theme.textSecondary)

                    fingerprintBlock(
                        title: "Previously trusted",
                        algorithm: error.stored.algorithm,
                        sha256: error.stored.sha256,
                        tint: Theme.textSecondary
                    )

                    fingerprintBlock(
                        title: "Seen now",
                        algorithm: error.seen.algorithm,
                        sha256: error.seen.sha256,
                        tint: Theme.red
                    )

                    VStack(spacing: 12) {
                        Button {
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.primary)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }

                        Button(role: .destructive) {
                            confirmingReset = true
                        } label: {
                            Text("Reset trust and reconnect")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .confirmationDialog(
                            "Forget the previously trusted fingerprint for \(error.host)?",
                            isPresented: $confirmingReset,
                            titleVisibility: .visible
                        ) {
                            Button("Forget trust", role: .destructive) {
                                onResetTrust()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("You'll be prompted to verify the new fingerprint on the next connect.")
                        }
                    }
                }
                .padding(24)
            }
            .background(Theme.background)
            .navigationTitle("Connection blocked")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }

    private func fingerprintBlock(title: String, algorithm: String, sha256: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            Text(algorithm)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(tint)
            Text(sha256)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(tint)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.background.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}
