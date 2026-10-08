// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct RootView: View {
    @Environment(\.appContainer) private var container
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var showCredentialReentry = false
    @State private var needsLibraryIndexPreparation = LibraryIndexSchema.needsPreparation

    var body: some View {
        if let serverState = container?.serverState {
            if serverState.isLoadingPersistedState || serverState.isSigningOut {
                ProgressView()
                    .controlSize(.large)
                    .tint(CassetteColors.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color("LaunchBackground").ignoresSafeArea())
            } else if serverState.activeServer != nil && onboardingComplete {
                #if os(macOS)
                RootViewMacOS()
                    .accentColor(.cassetteAccent)
                    .modifier(LibraryPreparationGate())
                    .modifier(CredentialReentryPresenter(
                        needsReentry: serverState.needsCredentialReentry,
                        showSheet: $showCredentialReentry,
                        container: container
                    ))
                #else
                // iPhone + iPad share MainTabView. On regular width, `.sidebarAdaptable`
                // provides the floating top tab bar (sidebar.left ↔ sidebar) and
                // `tabViewBottomAccessory` hosts the system mini player.
                if needsLibraryIndexPreparation, container?.libraryPreparationService.isPresentationDeferred != true {
                    EssentialSupportPreparationView(
                        onComplete: { needsLibraryIndexPreparation = false },
                        onReconnect: {}
                    )
                } else {
                    MainTabView()
                        .accentColor(.cassetteAccent)
                        .modifier(LibraryPreparationGate())
                        .modifier(CredentialReentryPresenter(
                            needsReentry: serverState.needsCredentialReentry,
                            showSheet: $showCredentialReentry,
                            container: container
                        ))
                }
                #endif
            } else {
                OnboardingView()
            }
        }
    }
}

/// Shows the library-preparation screen while a server-reported library change is applied, and
/// starts the check once the app is past onboarding for the active server.
private struct LibraryPreparationGate: ViewModifier {
    @Environment(\.appContainer) private var container

    func body(content: Content) -> some View {
        content
            .overlay {
                if container?.libraryPreparationService.phase.isPreparing == true,
                   container?.libraryPreparationService.isPresentationDeferred != true {
                    LibraryPreparationView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: container?.libraryPreparationService.phase)
            .task(id: container?.serverState.activeServer?.id) {
                guard let container, container.serverState.activeServer != nil else { return }
                await container.libraryPreparationService.prepareIfLibraryChanged(
                    serverService: container.serverService,
                    libraryService: container.libraryService,
                    indexService: container.libraryIndexService,
                    coverPreload: container.albumCoverPreloadService
                )
                // Let the finished checkmarks register before the screen goes away.
                if container.libraryPreparationService.phase == .complete {
                    try? await Task.sleep(for: .milliseconds(600))
                    container.libraryPreparationService.reset()
                }
            }
    }
}

/// Prompts the user to re-enter the server password when Keychain credentials are missing.
private struct CredentialReentryPresenter: ViewModifier {
    let needsReentry: Bool
    @Binding var showSheet: Bool
    let container: AppContainer?

    func body(content: Content) -> some View {
        content
            .onChange(of: needsReentry) { _, needs in
                // Keep the sheet in lockstep with the flag so a successful save dismisses it.
                showSheet = needs
            }
            .onAppear {
                if needsReentry { showSheet = true }
            }
            .sheet(isPresented: $showSheet, onDismiss: {
                // Swipe-dismiss without saving — reopen until credentials exist.
                if needsReentry {
                    showSheet = true
                } else if let container {
                    Task { await container.invalidateAPIClientsAfterCredentialChange() }
                }
            }) {
                if let server = container?.serverState.activeServer,
                   let serverService = container?.serverService {
                    NavigationStack {
                        EditServerDestinationView(server: server, serverService: serverService)
                    }
                    .interactiveDismissDisabled(needsReentry)
                }
            }
    }
}
