// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

private enum OnboardingStep {
    case language, serverSignIn, preparing, cache, albumCovers, listenBrainz, externalProviders, complete
}

struct OnboardingView: View {
    var isReplay = false
    var onReplayComplete: (() -> Void)? = nil
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep = .language
    @State private var serverViewModel: OnboardingViewModel?
    @State private var skippedAlbumCovers = false
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage(AppUILanguage.storageKey) private var appLanguageCode = ""
    /// Set by developer “show onboarding again” — bypasses the upgrade skip below.
    @AppStorage(AppContainer.DeveloperSettingsKey.forceOnboardingReplay)
    private var forceOnboardingReplay = false

    private var hasExistingServer: Bool {
        (isReplay || forceOnboardingReplay) && container?.serverState.activeServer != nil
    }

    private var appLocale: Locale {
        let code = appLanguageCode.isEmpty ? AppLanguage.current.code : appLanguageCode
        return Locale(identifier: code)
    }

    private var albumAssetsReady: Bool {
        container?.serverState.activeServer != nil
            && container?.albumCoverPreloadService.state.isComplete == true
    }

    private func advanceFromCache() {
        skippedAlbumCovers = albumAssetsReady
        step = skippedAlbumCovers ? .listenBrainz : .albumCovers
    }

    var body: some View {
        Group {
            switch step {
            case .language:
                OnboardingLanguageStepView(onContinue: {
                    step = hasExistingServer ? .cache : .serverSignIn
                })
                .transition(stepTransition)

            case .serverSignIn:
                if let serverViewModel {
                    OnboardingServerSignInView(
                        viewModel: serverViewModel,
                        // The first signed-in session prepares the library and its visual
                        // assets before exposing Home, avoiding a burst of placeholders.
                        onConnected: { step = .cache },
                        onBack: { step = .language }
                    )
                    .transition(stepTransition)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .cache:
                OnboardingCacheStepView(
                    onSkip: { advanceFromCache() },
                    onContinue: { advanceFromCache() },
                    totalSteps: albumAssetsReady ? 3 : 4
                )
                .transition(stepTransition)

            case .albumCovers:
                OnboardingAlbumCoversStepView(
                    onSkip: { step = .listenBrainz },
                    onContinue: { step = .listenBrainz },
                    onReconnect: { step = .serverSignIn }
                )
                .transition(stepTransition)

            case .listenBrainz:
                OnboardingListenBrainzStepView(
                    onSkip: { step = .externalProviders },
                    onContinue: { step = .externalProviders },
                    stepIndex: skippedAlbumCovers ? 1 : 2,
                    totalSteps: skippedAlbumCovers ? 3 : 4
                )
                .transition(stepTransition)

            case .externalProviders:
                OnboardingExternalProvidersStepView(
                    onSkip: { step = .preparing },
                    onContinue: { step = .preparing },
                    stepIndex: skippedAlbumCovers ? 2 : 3,
                    totalSteps: skippedAlbumCovers ? 3 : 4
                )
                .transition(stepTransition)

            case .preparing:
                EssentialSupportPreparationView(
                    onComplete: { step = .complete },
                    onReconnect: { step = .serverSignIn }
                )
                .transition(stepTransition)

            case .complete:
                OnboardingCompleteView(onComplete: { finishOnboarding() })
                    .transition(stepTransition)
            }
        }
        .environment(\.locale, appLocale)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: step)
        .task {
            if serverViewModel == nil, let container {
                serverViewModel = OnboardingViewModel(
                    serverService: container.serverService,
                    jellyfinService: container.jellyfinService,
                    jellyfinDiscoveryService: container.jellyfinDiscoveryService
                )
            }
            // Existing users upgrading: server already set, skip all onboarding steps.
            // Developer replay sets forceOnboardingReplay so this path must not fire.
            if !isReplay, !forceOnboardingReplay, container?.serverState.activeServer != nil {
                onboardingComplete = true
            }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        )
    }

    private func finishOnboarding() {
        if isReplay {
            onReplayComplete?()
            return
        }
        guard container?.serverState.activeServer != nil else {
            onboardingComplete = false
            step = .serverSignIn
            return
        }
        forceOnboardingReplay = false
        onboardingComplete = true
    }
}

#Preview {
    OnboardingView()
}
