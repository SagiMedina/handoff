import SwiftUI

/// QR code scanning screen using AVFoundation.
/// Full implementation in Phase 2.
struct ScanView: View {
    @EnvironmentObject var configStore: ConfigStore
    @Binding var path: NavigationPath

    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                // Camera preview placeholder — replaced with AVFoundation in Phase 2
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.surface)
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 48))
                                .foregroundColor(Theme.textSecondary)
                            Text("Camera preview")
                                .foregroundColor(Theme.textSecondary)
                        }
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 32)

                Text("Point at the QR code on your Mac")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(Theme.red)
                        .padding(.horizontal, 24)
                }
            }
        }
        .navigationTitle("Scan QR Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Called when QR content is detected. Parses payload and navigates.
    func handleScannedCode(_ value: String) {
        do {
            let config = try QRCodePayload.parse(value)
            configStore.save(config)
            // Pop back to root, which will show SessionsView since isPaired is now true
            path.removeLast(path.count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
