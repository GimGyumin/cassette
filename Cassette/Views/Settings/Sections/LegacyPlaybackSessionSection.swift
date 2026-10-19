import SwiftUI

/// Older releases did not record which server owned a saved queue. Let the listener
/// choose its owner explicitly; automatic restoration uses account-scoped sessions only.
struct LegacyPlaybackSessionSection: View {
    @Environment(\.appContainer) private var container
    @State private var available = false
    @State private var confirming = false
    @State private var restoring = false

    var body: some View {
        Group {
            if available, container?.playerState.currentTrack == nil {
                Section {
                    Button("Restore Previous Queue") { confirming = true }
                        .disabled(restoring)
                } footer: {
                    Text("A previous queue was saved without its server. Restore it only if it belongs to the currently selected server.")
                }
                .confirmationDialog("Restore to the Current Server?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Restore Queue") {
                        restoring = true
                        Task {
                            await container?.playerService.restoreLegacySession()
                            restoring = false
                            await refresh()
                        }
                    }
                } message: {
                    Text(container?.serverState.activeServer?.displayName ?? "")
                }
            }
        }
        .task(id: container?.serverState.activeServer?.id) { await refresh() }
    }

    private func refresh() async {
        guard let container, let account = container.serverState.activeServer?.id else { available = false; return }
        let legacy = await container.sessionService.hasLegacySession()
        let scoped = await container.sessionService.hasSession(for: account)
        guard container.serverState.activeServer?.id == account else { return }
        available = legacy && !scoped
    }
}
