// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import SwiftUI

/// A final gesture screen inspired by the system welcome handoff.
struct OnboardingWelcomeView: View {
    let onComplete: () -> Void

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 48)

                Image(systemName: "waveform")
                    .font(.system(size: 64, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                    .padding(.bottom, 28)

                Text(text("Welcome to Cassette"))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 48)

                Button(action: onComplete) {
                    VStack(spacing: 10) {
                        Image(systemName: "chevron.up")
                            .font(.title2.weight(.semibold))
                        Text(text("Swipe up to get started"))
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding.welcome.start")
                .padding(.bottom, 34)
            }
            .padding(.horizontal, 28)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .foregroundStyle(.white)
            .background {
                LinearGradient(
                    colors: [Color(red: 0.13, green: 0.30, blue: 0.75), Color(red: 0.30, green: 0.14, blue: 0.48)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 40).onEnded { gesture in
                    if gesture.translation.height < -80 { onComplete() }
                }
            )
        }
    }
}
