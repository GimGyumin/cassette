import SwiftUI

/// Password entry is explicit and uses the native secure text-field alert.
struct SubsonicPasswordVerificationAlert: ViewModifier {
    @Binding var server: ServerSnapshot?
    @Environment(\.appContainer) private var container
    @State private var password = ""
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var failedServer: ServerSnapshot?

    private var isPresented: Binding<Bool> {
        Binding(get: { server != nil }, set: { if !$0 { server = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert("Account Verification Required", isPresented: isPresented, presenting: server) { selected in
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Verify Account") { verify(selected) }
                    .disabled(password.isEmpty || isVerifying)
                Button("Cancel", role: .cancel) { password = "" }
            } message: { selected in
                Text("\(selected.username)\n\(selected.baseURL)\n\nEnter your account password to use Subsonic for library metadata, sharing, and playback. Your password is stored securely in Keychain.")
            }
            .alert("Account Verification Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Verify Account") { server = failedServer }
                Button("Cancel", role: .cancel) { failedServer = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func verify(_ selected: ServerSnapshot) {
        guard !isVerifying, !password.isEmpty, let container else { return }
        let submittedPassword = password
        password = ""
        isVerifying = true
        Task { @MainActor in
            defer { isVerifying = false }
            do {
                guard container.serverState.activeServer?.id == selected.id else {
                    throw CassetteError.serverNotFound(id: selected.id)
                }
                let identity = try container.serverState.requestIdentity(for: selected.id)
                let credentials = try await container.serverService.activeCredentials()
                guard container.serverState.requestIsCurrent(identity), !container.serverState.isSigningOut else { throw CancellationError() }
                try await container.serverService.testConnection(
                    url: selected.baseURL, username: selected.username,
                    password: submittedPassword, customHeaders: credentials.customHeaders
                )
                guard container.serverState.requestIsCurrent(identity), !container.serverState.isSigningOut else { throw CancellationError() }
                try await container.serverService.updateServer(
                    id: selected.id, displayName: selected.displayName,
                    baseURL: selected.baseURL, username: selected.username,
                    password: submittedPassword, customHeaders: credentials.customHeaders
                )
                failedServer = nil
            } catch {
                failedServer = selected
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Native confirmation first; password entry remains an explicit action on the detail page.
struct SubsonicAccountVerificationAlert: ViewModifier {
    @Binding var server: ServerSnapshot?
    @State private var detailServer: ServerSnapshot?

    func body(content: Content) -> some View {
        content
            .alert("Account Confirmation", isPresented: Binding(get: { server != nil }, set: { if !$0 { server = nil } }), presenting: server) { selected in
                Button("Later", role: .cancel) {}
                Button("Verify Account") { detailServer = selected }
            } message: { selected in
                Text("\(selected.username)\n\(selected.baseURL)\n\nConfirm your server account to enable library metadata, sharing, and playback through Subsonic. You can also complete this later in Account.")
            }
            .sheet(isPresented: Binding(get: { detailServer != nil }, set: { if !$0 { detailServer = nil } })) {
                if let detailServer {
                    NavigationStack {
                        AccountVerificationView(server: detailServer)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { self.detailServer = nil }
                                }
                            }
                    }
                }
            }
    }
}

struct AccountVerificationView: View {
    let server: ServerSnapshot
    @Environment(\.appContainer) private var container
    @State private var passwordServer: ServerSnapshot?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Account Verification Required").font(.headline)
                    Text("Verify your server account to use library metadata, sharing, and playback through Subsonic. Your password is saved securely in Keychain.")
                        .foregroundStyle(.secondary)
                    Text(server.username).font(.subheadline)
                    Text(server.baseURL).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(.vertical, 8)
                if container?.serverState.needsSubsonicVerification == true {
                    Button("Verify Account") { passwordServer = server }
                        .disabled(container?.serverState.activeServer?.id != server.id || container?.serverState.isSigningOut == true)
                } else {
                    Label("Account Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle("Account Verification")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .modifier(SubsonicPasswordVerificationAlert(server: $passwordServer))
    }
}

struct AccountVerificationRow: View {
    let server: ServerSnapshot
    var body: some View {
        NavigationLink {
            AccountVerificationView(server: server)
        } label: {
            HStack {
                Text("Account Verification Required")
                Spacer()
                Text("1").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(6).background(.red, in: Circle())
                    .accessibilityLabel(Text("One account action required"))
            }
        }
    }
}

/// Once per account per launch, after the foreground home settles for five seconds.
struct AccountVerificationLaunchPrompt: ViewModifier {
    @Environment(\.appContainer) private var container
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var promptedServers: Set<UUID> = []
    @State private var selectedServer: ServerSnapshot?

    private var accountRequiringVerification: UUID? {
        guard let container, scenePhase == .active, onboardingComplete,
              !container.serverState.isLoadingPersistedState, !container.serverState.isSigningOut,
              !container.serverState.needsCredentialReentry,
              container.serverState.needsSubsonicVerification,
              !container.libraryPreparationService.phase.isPreparing || container.libraryPreparationService.isPresentationDeferred else { return nil }
        return container.serverState.activeServer?.id
    }

    func body(content: Content) -> some View {
        content
            .task(id: accountRequiringVerification) {
                guard let id = accountRequiringVerification, !promptedServers.contains(id) else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled, accountRequiringVerification == id,
                      let server = container?.serverState.activeServer, server.id == id else { return }
                promptedServers.insert(id)
                selectedServer = server
            }
            .onChange(of: container?.serverState.activeServer?.id) { _, id in
                if selectedServer?.id != id { selectedServer = nil }
            }
            .onChange(of: container?.serverState.isSigningOut) { _, signingOut in
                if signingOut == true { selectedServer = nil }
            }
            .modifier(SubsonicAccountVerificationAlert(server: $selectedServer))
    }
}
