import SwiftUI
import AVFoundation

/// QR code scanning screen using AVFoundation.
/// Camera starts immediately; on QR detection, parses the Handoff JSON payload,
/// saves config, and navigates to the sessions screen.
struct ScanView: View {
    @EnvironmentObject var configStore: ConfigStore
    @Binding var path: NavigationPath

    @State private var errorMessage: String?
    @State private var cameraPermission: CameraPermission = .unknown
    @State private var scannerController: QRScannerController?

    enum CameraPermission {
        case unknown, granted, denied
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch cameraPermission {
            case .unknown:
                ProgressView()
            case .granted:
                cameraView
            case .denied:
                permissionDeniedView
            }
        }
        .navigationTitle("Scan QR Code")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkCameraPermission()
        }
    }

    // MARK: - Camera view

    private var cameraView: some View {
        ZStack {
            QRScannerRepresentable(
                onCodeScanned: { value in
                    handleScannedCode(value)
                },
                onControllerReady: { controller in
                    scannerController = controller
                }
            )
            .ignoresSafeArea()

            // Viewfinder overlay
            VStack {
                Spacer()

                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.primary.opacity(0.6), lineWidth: 2)
                    .frame(width: 250, height: 250)

                Spacer()
                    .frame(height: 32)

                Text("Point at the QR code on your Mac")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6))
                    .cornerRadius(8)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(Theme.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.top, 8)
                }

                Spacer()
                    .frame(height: 64)
            }
        }
    }

    // MARK: - Permission denied

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(Theme.textSecondary)

            Text("Camera access is needed to scan the pairing QR code.")
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .foregroundColor(Theme.primary)
        }
    }

    // MARK: - Logic

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermission = .granted
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraPermission = granted ? .granted : .denied
                }
            }
        default:
            cameraPermission = .denied
        }
    }

    private func handleScannedCode(_ value: String) {
        do {
            let config = try QRCodePayload.parse(value)
            configStore.save(config)
            // Pop back to root — ContentView will show SessionsView since isPaired is now true
            if !path.isEmpty {
                path.removeLast(path.count)
            }
        } catch {
            errorMessage = error.localizedDescription
            // Reset scanner to allow rescanning after parse failure
            scannerController?.resetScanning()
        }
    }
}

// MARK: - UIViewControllerRepresentable

/// Bridges QRScannerController into SwiftUI.
struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    let onControllerReady: (QRScannerController) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCodeScanned = onCodeScanned
        onControllerReady(controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {
        // No dynamic updates needed
    }
}
