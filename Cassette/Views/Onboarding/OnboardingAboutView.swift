// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import SwiftUI

/// Optional services stay in Account; this brief overview closes setup.
struct OnboardingAboutView: View {
    let onContinue: () -> Void

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        NavigationStack {
            CassetteSplashView(
                title: text("About Cassette"),
                summary: text("Your music feels at home here."),
                icon: "waveform",
                accent: .blue,
                features: [
                    .init(icon: "server.rack", title: text("Your library, your way"),
                          detail: text("Listen to the music on your own server, all in one place.")),
                    .init(icon: "arrow.down.circle.fill", title: text("Ready wherever you go"),
                          detail: text("Downloads and smart caching keep favorite tracks close.")),
                    .init(icon: "waveform", title: text("Sound that suits you"),
                          detail: text("Enjoy gapless playback, quality controls, and ReplayGain.")),
                    .init(icon: "text.quote", title: text("Closer to every song"),
                          detail: text("Follow lyrics and translations when they are available.")),
                    .init(icon: "sparkles", title: text("More to discover"),
                          detail: text("Explore your collection and find fresh music when you choose."))
                ],
                footnote: text("Optional services are ready in Account whenever you want them."),
                buttonTitle: text("Continue"),
                buttonIdentifier: "onboarding.about.continue",
                onContinue: onContinue
            )
        }
    }
}
