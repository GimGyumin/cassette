import SwiftUI

/// Uses the system password alert for both the launch prompt and account settings.
struct SubsonicAccountVerificationAlert: ViewModifier {
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
                let credentials = try await container.serverService.activeCredentials()
                try await container.serverService.testConnection(
                    url: selected.baseURL, username: selected.username,
                    password: submittedPassword, customHeaders: credentials.customHeaders
                )
                guard container.serverState.activeServer?.id == selected.id else {
                    throw CassetteError.serverNotFound(id: selected.id)
                }
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

/// Once per account per app launch; cancelling leaves the account entry available.
struct AccountVerificationLaunchPrompt: ViewModifier {
    @Environment(\.appContainer) private var container
    @State private var promptedServers: Set<UUID> = []
    @State private var selectedServer: ServerSnapshot?

    private var accountRequiringVerification: UUID? {
        guard let container, !container.serverState.isLoadingPersistedState,
              container.serverState.needsSubsonicVerification else { return nil }
        return container.serverState.activeServer?.id
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: accountRequiringVerification, initial: true) { _, id in
                guard let id, !promptedServers.contains(id),
                      let server = container?.serverState.activeServer else { return }
                promptedServers.insert(id)
                selectedServer = server
            }
            .modifier(SubsonicAccountVerificationAlert(server: $selectedServer))
    }
}
