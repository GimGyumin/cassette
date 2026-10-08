// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

private enum OnboardingStep {
    case language, serverSignIn, cache, albumCovers, about, welcome
}

struct OnboardingView: View {
    var isReplay = false
    var onReplayComplete: (() -> Void)? = nil
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep = .language
    @State private var serverViewModel: OnboardingViewModel?
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("cassette.onboarding.pendingWelcome") private var pendingWelcome = false
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
        step = albumAssetsReady ? .about : .albumCovers
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
                        // Keep optional services in their own menus; first sign-in ends with
                        // a short introduction before entering the library.
                        onConnected: {
                            if isReplay || forceOnboardingReplay {
                                step = .cache
                            } else {
                                pendingWelcome = true
                                step = .about
                            }
                        },
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
                    totalSteps: albumAssetsReady ? 2 : 3
                )
                .transition(stepTransition)

            case .albumCovers:
                OnboardingAlbumCoversStepView(
                    onSkip: { step = .about },
                    onContinue: { step = .about },
                    onReconnect: { step = .serverSignIn }
                )
                .transition(stepTransition)

            case .about:
                OnboardingAboutView(onContinue: { step = .welcome })
                    .transition(stepTransition)

            case .welcome:
                OnboardingWelcomeView(onComplete: { finishOnboarding() })
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
                if pendingWelcome {
                    step = .about
                } else {
                    onboardingComplete = true
                }
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
        pendingWelcome = false
        // Users can listen as soon as sign-in succeeds. Search prepares in the
        // background; full-library artwork can be requested from Storage.
        container?.libraryPreparationService.deferPresentation()
        if let container {
            container.libraryIndexService.ensureIndexed(using: container.libraryService)
        }
        onboardingComplete = true
    }
}

#Preview {
    OnboardingView()
}
