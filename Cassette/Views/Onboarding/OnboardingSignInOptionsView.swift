import SwiftUI

/// Secondary sign-in methods and nearby servers, separate from the main credential form.
struct OnboardingSignInOptionsView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onQuickConnect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var showsNearbyServers = false

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppUILanguage.localizationBundle(for: locale), locale: locale)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 20) {
                        ZStack {
                            Circle().strokeBorder(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 6, dash: [1, 12]))
                                .frame(width: 104, height: 104)
                            CassetteTapeIcon().fill(Color.blue, style: FillStyle(eoFill: true))
                                .frame(width: 46, height: 32)
                        }
                        .accessibilityHidden(true)
                        Text(text("Sign in to Cassette"))
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(text("Choose how to connect to your music server."))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        if viewModel.hasEnteredServerURL {
                            Text(viewModel.derivedDisplayName)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 24)

                    VStack(spacing: 18) {
                        if viewModel.supportsQuickConnect {
                            Button(action: onQuickConnect) {
                                optionCard(icon: "ipad.and.iphone", title: text("Quick Connect"),
                                           detail: text("Approve a code on a signed-in device to connect without a password."))
                            }
                            .accessibilityIdentifier("onboarding.server.quickConnect")
                        }
                        Button { showsNearbyServers = true } label: {
                            optionCard(icon: "network", title: text("Nearby Servers"),
                                       detail: text("Choose a music server on your Wi-Fi network."))
                        }
                        .accessibilityIdentifier("onboarding.server.nearby")
                        if viewModel.jellyfinStatus == .checking {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(text("Checking sign-in options…")).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    DisclosureGroup(text("Custom Headers")) {
                        VStack(spacing: 14) {
                            ForEach($viewModel.customHeaders) { $header in
                                CustomHeaderRowView(key: $header.key, value: $header.value,
                                                    onRemove: { viewModel.removeCustomHeader(id: header.id) })
                            }
                            Button(action: viewModel.addCustomHeader) { Label(text("Add Header"), systemImage: "plus") }
                            Text(text("Only needed if your server administrator provided additional connection settings."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.top, 16)
                    }
                    .padding(22)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 24))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background { SetupBackground() }
            .navigationDestination(isPresented: $showsNearbyServers) { nearbyServers }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .cassetteGlassButton(size: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(text("Close"))
                }
            }
        }
        .tint(.blue)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
    }

    private func optionCard(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 20) {
            // Icon in a soft rounded box — the same shape the system account sheet uses for its rows.
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.blue)
                .frame(width: 56, height: 56)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }

    private var nearbyServers: some View {
        List {
            Section {
                switch viewModel.discoveryState {
                case .idle, .searching:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(text("Searching for nearby servers…"))
                    }
                case .finished:
                    if viewModel.discoveredServers.isEmpty {
                        Text(text("No Jellyfin or Navidrome servers were found.")).foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.discoveredServers) { server in
                        Button {
                            viewModel.useDiscoveredServer(server)
                            showsNearbyServers = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text(server.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.serverURL == server.address { Image(systemName: "checkmark") }
                            }
                        }
                    }
                case .permissionDenied, .failed:
                    Text(text("Cassette couldn't reach your local network. Allow Local Network access for Cassette in Settings, then try again."))
                        .foregroundStyle(.secondary)
                    Button(text("Open Settings")) { CassetteSystemSettings.openAppSettings() }
                }
                if viewModel.discoveryState != .searching {
                    Button(text("Try Again")) {
                        Task { await viewModel.discoverLANServers() }
                    }
                }
            } footer: {
                Text(text("Find compatible music servers on your Wi-Fi network."))
            }
        }
        .navigationTitle(text("Nearby Servers"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if viewModel.discoveryState == .idle { await viewModel.discoverLANServers() }
        }
    }
}
