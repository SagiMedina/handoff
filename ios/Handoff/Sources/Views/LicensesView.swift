import SwiftUI

private struct LicenseLibrary: Identifiable {
    let name: String
    let license: String
    let url: String
    let bundledLicenseResource: String?

    init(
        name: String,
        license: String,
        url: String,
        bundledLicenseResource: String? = nil
    ) {
        self.name = name
        self.license = license
        self.url = url
        self.bundledLicenseResource = bundledLicenseResource
    }

    var id: String { name }
}

private let iosLibraries: [LicenseLibrary] = [
    .init(
        name: "TailscaleKit",
        license: "BSD-3-Clause",
        url: "https://github.com/tailscale/libtailscale"
    ),
    .init(
        name: "SwiftTerm",
        license: "MIT",
        url: "https://github.com/migueldeicaza/SwiftTerm"
    ),
    .init(
        name: "SwiftNIO SSH",
        license: "Apache 2.0",
        url: "https://github.com/apple/swift-nio-ssh"
    ),
    .init(
        name: "SwiftNIO",
        license: "Apache 2.0",
        url: "https://github.com/apple/swift-nio"
    ),
    .init(
        name: "Swift Crypto",
        license: "Apache 2.0",
        url: "https://github.com/apple/swift-crypto"
    ),
    .init(
        name: "MesloLGS Nerd Font Mono (Nerd Fonts)",
        license: "Apache 2.0",
        url: "https://github.com/ryanoasis/nerd-fonts",
        bundledLicenseResource: "MesloLGSNerdFontMono-LICENSE"
    ),
]

struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Handoff for iOS uses the following open source libraries.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)

                ForEach(iosLibraries) { library in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(library.name)
                                .font(.headline)
                                .foregroundColor(Theme.text)
                            Spacer()
                            Text(library.license)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.textSecondary)
                        }

                        Link(destination: URL(string: library.url)!) {
                            Text(library.url)
                                .font(.footnote)
                                .foregroundColor(Theme.primary)
                                .multilineTextAlignment(.leading)
                        }

                        if let resource = library.bundledLicenseResource {
                            NavigationLink {
                                BundledLicenseView(resourceName: resource)
                            } label: {
                                Text("View bundled license")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(Theme.primary)
                            }
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
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BundledLicenseView: View {
    let resourceName: String

    private var licenseText: String {
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "txt"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled license text could not be loaded."
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("License")
        .navigationBarTitleDisplayMode(.inline)
    }
}
