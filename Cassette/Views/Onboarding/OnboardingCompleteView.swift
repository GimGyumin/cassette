// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct OnboardingCompleteView: View {
    let onComplete: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                SetupHeader(icon: "checkmark.circle", title: String(localized: "Setup Complete", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            subtitle: String(localized: "You’re ready to start listening.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .padding(.horizontal, 24)
                    .padding(.top, 60)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .background { SetupBackground() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(String(localized: "Continue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), action: onComplete)
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.complete.continue")
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .background { SetupBackground() }
            }
        }
    }
}
