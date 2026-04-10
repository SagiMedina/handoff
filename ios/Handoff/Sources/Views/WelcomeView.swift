import SwiftUI

/// First-launch screen prompting the user to pair with their Mac.
struct WelcomeView: View {
    @Binding var path: NavigationPath

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
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }
}
