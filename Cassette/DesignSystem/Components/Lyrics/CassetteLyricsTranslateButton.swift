// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Translate / reveal / clear control for loaded lyrics. Shared by iOS FullPlayer and macOS Expanded player.
/// Long-press (menu) exposes server-provided translation tracks from songLyrics v2.
struct CassetteLyricsTranslateButton: View {
    @Bindable var lyricsViewModel: LyricsViewModel
    let contentColor: Color
    var buttonSize: CGFloat = 44
    var iconSize: CGFloat = 15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var translationToggleAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.01)
            : .easeInOut(duration: 0.38)
    }

    private var isActive: Bool {
        lyricsViewModel.areTranslationsVisible
            || (lyricsViewModel.hasPronunciation && lyricsViewModel.arePronunciationsVisible)
    }

    var body: some View {
        if lyricsViewModel.isTranslating {
            ProgressView()
                .tint(contentColor)
                .controlSize(.small)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
                .background {
                    translationButtonBackground(isActive: false)
                }
        } else {
            Menu {
                Button {
                    HapticFeedback.light.trigger()
                    lyricsViewModel.togglePronunciationVisibility()
                } label: {
                    Label(
                        lyricsViewModel.arePronunciationsVisible
                            ? String(localized: "Hide pronunciation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                            : String(localized: "Show pronunciation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        systemImage: lyricsViewModel.arePronunciationsVisible
                            ? "captions.bubble.fill"
                            : "captions.bubble"
                    )
                }
                .disabled(!lyricsViewModel.hasPronunciation)

                Button {
                    HapticFeedback.light.trigger()
                    toggleClientTranslation()
                } label: {
                    if lyricsViewModel.areTranslationsVisible {
                        Label(String(localized: "Hide translation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "translate")
                    } else if lyricsViewModel.hasStoredTranslation {
                        Label(String(localized: "Show translation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "translate")
                    } else {
                        Label(String(localized: "Translate", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "translate")
                    }
                }

                if !lyricsViewModel.availableServerTranslations.isEmpty {
                    Section(String(localized: "Server translations", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                        ForEach(lyricsViewModel.availableServerTranslations, id: \.lang) { track in
                            Button {
                                HapticFeedback.light.trigger()
                                Task { await lyricsViewModel.selectServerTranslation(lang: track.lang) }
                            } label: {
                                if lyricsViewModel.selectedServerTranslationLang == track.lang {
                                    Label(track.title, systemImage: "checkmark")
                                } else {
                                    Text(track.title)
                                }
                            }
                        }
                        if lyricsViewModel.selectedServerTranslationLang != nil {
                            Button(String(localized: "Use app translation", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                                Task { await lyricsViewModel.selectServerTranslation(lang: nil) }
                            }
                        }
                    }
                }

            } label: {
                Image(systemName: "translate")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(
                        isActive
                            ? Color.black.opacity(0.72)
                            : contentColor
                    )
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Circle())
                    .background {
                        translationButtonBackground(isActive: isActive)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                lyricsViewModel.areTranslationsVisible
                    ? "Hide translation"
                    : "Translate lyrics"
            )
        }
    }

    private func translationButtonBackground(isActive: Bool) -> some View {
        Circle()
            .fill(.regularMaterial)
            .overlay {
                Circle()
                    .fill(
                        isActive
                            ? Color.white.opacity(0.52)
                            : contentColor.opacity(0.20)
                    )
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
    }

    private func toggleClientTranslation() {
        if lyricsViewModel.areTranslationsVisible {
            withAnimation(translationToggleAnimation) {
                lyricsViewModel.clearTranslation()
            }
        } else if lyricsViewModel.hasStoredTranslation {
            withAnimation(translationToggleAnimation) {
                lyricsViewModel.revealTranslation()
            }
        } else {
            Task { await lyricsViewModel.translateCurrentLyrics() }
        }
    }
}
