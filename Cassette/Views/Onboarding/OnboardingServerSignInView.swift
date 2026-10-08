import SwiftUI

/// A stable, staged sign-in surface. Secondary setup lives in an options sheet.
struct OnboardingServerSignInView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onConnected: () -> Void
    var onBack: (() -> Void)? = nil

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var stage: Stage = .server
    @State private var showsOptions = false
    @State private var isShowingHTTPConfirmation = false
    @State private var isConnecting = false
    @State private var pendingConnection: PendingConnection = .password
    @State private var quickConnectTask: Task<Void, Never>?

    private enum Field: Hashable { case url, username, password }
    private enum Stage { case server, credentials, quickConnect }
    private enum PendingConnection { case password, quickConnect }
    private var isBusy: Bool { isConnecting || viewModel.isLoading }
    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppUILanguage.localizationBundle(for: locale), locale: locale)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                navigationHeader
                GeometryReader { geometry in
                    if stage == .quickConnect {
                        quickConnectContent
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                brandHeader
                                stageContent
                                Spacer(minLength: 24)
                                privacyNote
                            }
                            .padding(.horizontal, 32)
                            .padding(.top, 16)
                            .padding(.bottom, 20)
                            .frame(maxWidth: 540)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                            .frame(maxWidth: .infinity)
                        }
                        #if os(iOS)
                        .scrollDismissesKeyboard(.interactively)
                        #endif
                    }
                }
            }
            .background { SetupBackground() }
            .tint(.blue)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if stage != .quickConnect { actions }
            }
            .sheet(isPresented: $showsOptions) {
                OnboardingSignInOptionsView(viewModel: viewModel) {
                    showsOptions = false
                    requestQuickConnect()
                }
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                #endif
            }
            .task { await viewModel.discoverLANServers() }
            .task(id: viewModel.jellyfinProbeKey) { await viewModel.probeJellyfin() }
            .onChange(of: viewModel.jellyfinProbeKey) { _, _ in
                cancelQuickConnect()
                if stage == .quickConnect { stage = .server }
            }
            .onDisappear { cancelQuickConnect() }
        }
        .alert("Use an unencrypted connection?", isPresented: $isShowingHTTPConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue Anyway", role: .destructive) {
                switch pendingConnection {
                case .password: Task { await connect() }
                case .quickConnect: startQuickConnect()
                }
            }
        } message: {
            Text("HTTP can expose your server address, username, password, and music traffic to people on the network. Continue only on a network you trust.")
        }
    }

    private var navigationHeader: some View {
        ZStack {
            HStack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)
                        .cassetteGlassButton(size: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text("Back"))
                .accessibilityIdentifier("onboarding.server.back")
                .disabled(isConnecting)
                Spacer()
            }

            if stage == .quickConnect {
                Text(viewModel.derivedDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 72)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.07)).frame(width: 112, height: 112)
                Circle().strokeBorder(Color.blue.opacity(0.25), style: StrokeStyle(lineWidth: 5, dash: [1, 11]))
                    .frame(width: 102, height: 102)
                CassetteTapeIcon().fill(Color.blue, style: FillStyle(eoFill: true))
                    .frame(width: 46, height: 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .accessibilityHidden(true)
            Text(stage == .quickConnect ? text("Quick Connect") : text("Sign in to Cassette"))
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text(stage == .server ? text("Connect your music server to listen to your library.")
                 : stage == .credentials ? text("Enter your username and password to continue.")
                 : text("Approve this device from your server to continue."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .server:
            VStack(alignment: .leading, spacing: 14) {
                // Bare-host prompt (`verbatim` so no catalog entry is generated): no scheme is required here.
                TextField(
                    text: $viewModel.serverURL,
                    prompt: Text(verbatim: "music.example.com")
                ) {
                    EmptyView()
                }
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.continue)
                    #endif
                    .focused($focusedField, equals: .url)
                    .onSubmit { continueFromServer() }
                    .textFieldStyle(.plain)
                    .padding(20)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                    .accessibilityLabel(text("Server address"))
                    .accessibilityIdentifier("onboarding.server.url")
                // The placeholder is a bare host on purpose: no scheme is required in this field.
                Text(text("Enter your server address, such as music.example.com. HTTPS is added automatically."))
                    .font(.footnote).foregroundStyle(.secondary)
                if case .invalidURL = viewModel.connectionError {
                    Text(text("Enter a valid server address."))
                        .font(.footnote).foregroundStyle(.red)
                }
            }
        case .credentials:
            VStack(alignment: .leading, spacing: 18) {
                serverLabel
                VStack(spacing: 0) {
                    TextField(text("Username"), text: $viewModel.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        #endif
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                        .padding(20)
                        .accessibilityIdentifier("onboarding.server.username")
                    Divider().padding(.horizontal, 20)
                    SecureField(text("Password"), text: $viewModel.password)
                        .textContentType(.password)
                        #if os(iOS)
                        .submitLabel(.go)
                        #endif
                        .focused($focusedField, equals: .password)
                        .onSubmit { requestConnect() }
                        .padding(20)
                        .accessibilityIdentifier("onboarding.server.password")
                }
                .textFieldStyle(.plain)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 26))
                .disabled(isBusy)
                if let error = viewModel.connectionError {
                    ConnectionErrorView(error: error)
                }
            }
        case .quickConnect:
            EmptyView()
        }
    }

    private var serverLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            Text(viewModel.derivedDisplayName).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(text("Change")) { cancelQuickConnect(); stage = .server }
                .disabled(isConnecting)
        }
        .font(.footnote)
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.blue)
            Text(text("Your sign-in details are stored securely in this device’s Keychain."))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                switch stage {
                case .server: continueFromServer()
                case .credentials: requestConnect()
                case .quickConnect: break
                }
            } label: {
                HStack(spacing: 10) {
                    if isConnecting || (viewModel.isLoading && stage == .credentials) { ProgressView().tint(.white) }
                    Text(isBusy ? text("Signing In…") : text("Continue"))
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(primaryEnabled ? Color.white : Color.secondary)
                .background(primaryEnabled ? Color.blue : Color.secondary.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .accessibilityIdentifier("onboarding.server.continue")
            Button(text("Other Sign-In Options")) { focusedField = nil; showsOptions = true }
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .cassetteGlassCapsule()
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("onboarding.server.options")
        }
        .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 18)
        .frame(maxWidth: 540).frame(maxWidth: .infinity)
        .background { SetupBackground() }
    }

    private var primaryEnabled: Bool {
        if stage == .quickConnect { return false }
        return !isBusy && (stage == .server ? viewModel.hasEnteredServerURL : viewModel.canSubmit)
    }

    private var quickConnectContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(text("Open your server in a browser, choose Quick Connect, and approve this code."))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 56)

                Spacer(minLength: 72)

                switch viewModel.quickConnectState {
                case .idle, .starting:
                    VStack(spacing: 18) {
                        ProgressView()
                            .controlSize(.large)
                        Text(text("Preparing Quick Connect…"))
                            .foregroundStyle(.secondary)
                    }
                case .completing:
                    VStack(spacing: 18) {
                        ProgressView()
                            .controlSize(.large)
                        Text(text("Finishing Sign-In…"))
                            .foregroundStyle(.secondary)
                    }
                case .awaitingApproval(let code):
                    VStack(spacing: 36) {
                        Text(code)
                            .font(.system(size: 72, weight: .light, design: .monospaced))
                            .tracking(14)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 112)
                            .accessibilityLabel(text("Quick Connect code"))
                            .accessibilityValue(code)

                        HStack(spacing: 10) {
                            ProgressView()
                            Text(text("Waiting for approval…"))
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(spacing: 20) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(text("Try Quick Connect Again")) { requestQuickConnect() }
                            .buttonStyle(SetupPrimaryButtonStyle())
                            .disabled(isBusy)
                    }
                    .frame(maxWidth: 420)
                }

                Spacer(minLength: 80)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("onboarding.server.quickConnectCode")
    }

    private func continueFromServer() {
        guard !isBusy, viewModel.hasEnteredServerURL else { return }
        focusedField = nil
        viewModel.connectionError = nil
        stage = .credentials
    }

    private func goBack() {
        focusedField = nil
        if stage == .quickConnect {
            cancelQuickConnect()
            stage = .credentials
            showsOptions = true
            return
        }
        cancelQuickConnect()
        if stage != .server { stage = .server }
        else if let onBack { onBack() }
        else { dismiss() }
    }

    private func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        viewModel.resetQuickConnect()
    }

    private func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        focusedField = nil
        guard await viewModel.addServer(), !Task.isCancelled else { return }
        await PasswordAutoFillOffer.offerSaveAfterSuccessfulLogin()
        guard !Task.isCancelled else { return }
        onConnected()
    }

    private func requestConnect() {
        guard !isBusy, viewModel.canSubmit else { return }
        focusedField = nil
        pendingConnection = .password
        if viewModel.isHTTP { isShowingHTTPConfirmation = true }
        else { Task { await connect() } }
    }

    private func requestQuickConnect() {
        guard !isBusy, viewModel.hasEnteredServerURL, viewModel.supportsQuickConnect else { return }
        focusedField = nil
        pendingConnection = .quickConnect
        if viewModel.isHTTP { isShowingHTTPConfirmation = true }
        else { startQuickConnect() }
    }

    private func startQuickConnect() {
        quickConnectTask?.cancel()
        stage = .quickConnect
        quickConnectTask = Task {
            guard await viewModel.signInWithQuickConnect(), !Task.isCancelled else { return }
            onConnected()
        }
    }
}
