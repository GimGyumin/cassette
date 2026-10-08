// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import SwiftUI

/// Compact, accessible introduction shared by onboarding and optional services.
struct CassetteSplashView: View {
    struct Feature: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { icon }
    }

    let title: String
    let summary: String
    let icon: String
    let accent: Color
    let features: [Feature]
    let footnote: String?
    let buttonTitle: String
    let buttonIdentifier: String
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                    .padding(.top, 32)

                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 30)

                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 22) {
                    ForEach(features) { feature in
                        HStack(alignment: .top, spacing: 15) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(accent)
                                .frame(width: 28)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(feature.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 31)

                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 36)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(PlatformColors.systemBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onContinue) {
                Text(buttonTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(buttonIdentifier)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
            .background(PlatformColors.systemBackground)
        }
    }
}
