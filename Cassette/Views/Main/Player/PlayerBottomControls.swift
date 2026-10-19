// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

#if canImport(UIKit)
import AVKit
import AVFoundation
#endif

// MARK: - Bottom toolbar

struct BottomToolbar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var surface: PlayerSurface
    let isLiveStream: Bool
    var lyricsEnabled: Bool = true
    var lyricsViewModel: LyricsViewModel?
    var translateEnabled: Bool = false
    let contentColor: Color
    let secondaryContentColor: Color
    let playerState: PlayerState
    var spreadToEdges: Bool = false

    private var glyphColor: Color { secondaryContentColor }

    var body: some View {
        HStack(spacing: spreadToEdges ? CassetteSpacing.m : 0) {
            if spreadToEdges {
                AudioOutputRouteButton(tintColor: glyphColor)
                    .accessibilityLabel(String(localized: "Audio output", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                Spacer(minLength: 0)
                lyricsButton
                translateButton
                queueButton
            } else {
                lyricsButton
                    .frame(maxWidth: .infinity)
                if translateEnabled {
                    translateButton
                        .frame(maxWidth: .infinity)
                }
                AudioOutputRouteButton(tintColor: glyphColor)
                    .accessibilityLabel(String(localized: "Audio output", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .frame(maxWidth: .infinity)
                queueButton
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var lyricsButton: some View {
        if !isLiveStream {
            Button {
                guard lyricsEnabled else { return }
                withAnimation(reduceMotion ? nil : CassetteAnimation.surface) {
                    surface = (surface == .lyrics) ? .player : .lyrics
                }
            } label: {
                toolbarGlyph(
                    "quote.bubble",
                    isActive: surface == .lyrics
                )
                .opacity(lyricsEnabled ? 1 : 0.35)
            }
            .buttonStyle(.borderless)
            .disabled(!lyricsEnabled)
            .accessibilityLabel(String(localized: "Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityAddTraits(surface == .lyrics ? .isSelected : [])
        }
    }

    @ViewBuilder
    private var translateButton: some View {
        if translateEnabled, let lyricsViewModel {
            CassetteLyricsTranslateButton(
                lyricsViewModel: lyricsViewModel,
                contentColor: glyphColor,
                buttonSize: 44,
                iconSize: 15
            )
        }
    }

    @ViewBuilder
    private var queueButton: some View {
        if !isLiveStream {
            Button {
                withAnimation(reduceMotion ? nil : CassetteAnimation.surface) {
                    surface = (surface == .queue) ? .player : .queue
                }
            } label: {
                toolbarGlyph(
                    "list.bullet",
                    isActive: surface == .queue
                )
                .overlay(alignment: .topTrailing) {
                    if let badge = playerState.queueModeBadge {
                        Image(systemName: badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(glyphColor)
                            .padding(2)
                            .background(contentColor.opacity(0.92), in: Circle())
                            .overlay(Circle().stroke(glyphColor.opacity(0.25), lineWidth: 0.5))
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : CassetteAnimation.interactive, value: playerState.queueModeBadge)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityAddTraits(surface == .queue ? .isSelected : [])
        }
    }

    private func toolbarGlyph(_ systemName: String, isActive: Bool) -> some View {
        Image(systemName: systemName)
            .font(.title3)
            .foregroundStyle(isActive ? Color.black.opacity(0.72) : glyphColor)
            .padding(CassetteSpacing.m)
            .background {
                if isActive {
                    Circle()
                        .fill(Color.white.opacity(0.68))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                }
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : CassetteAnimation.interactive, value: isActive)
    }
}

#if canImport(UIKit)
private struct AudioOutputRouteButton: View {
    var tintColor: Color = Color.white.opacity(0.7)
    @State private var routeName = ""

    private var visibleRouteName: String {
        let lowercased = routeName.lowercased()
        if lowercased.contains("airpods")
            || lowercased.contains("homepod")
            || lowercased.contains("beats") {
            return " \(routeName)"
        }
        return routeName
    }

    var body: some View {
        NativeRoutePicker(tintColor: tintColor)
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottom) {
            if !routeName.isEmpty {
                Text(verbatim: visibleRouteName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tintColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 116)
                    .offset(y: 20)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { refreshRoutePresentation() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
            refreshRoutePresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshRoutePresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteRoutePickerDidDismiss)) { _ in
            refreshRoutePresentation()
        }
        .accessibilityLabel(routeName)
    }

    private func refreshRoutePresentation() {
        let route = AVAudioSession.sharedInstance().currentRoute
        routeName = RouteSymbol.displayName(for: route)
    }
}

private struct NativeRoutePicker: UIViewRepresentable {
    let tintColor: Color
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = UIColor(tintColor)
        view.activeTintColor = UIColor(tintColor)
        view.prioritizesVideoDevices = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tintColor)
        uiView.activeTintColor = UIColor(tintColor)
        if uiView.delegate !== context.coordinator {
            uiView.delegate = context.coordinator
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            NotificationCenter.default.post(name: .cassetteRoutePickerWillPresent, object: nil)
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            NotificationCenter.default.post(name: .cassetteRoutePickerDidDismiss, object: nil)
        }
    }
}

private enum RouteSymbol {
    static func displayName(for route: AVAudioSessionRouteDescription) -> String {
        guard let output = preferredOutput(for: route) else {
            return String(localized: "Audio output", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }

        switch output.portType {
        case .builtInSpeaker, .builtInReceiver:
            return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        default:
            let name = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty
                ? String(localized: "Audio output", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : name
        }
    }

    private static func preferredOutput(
        for route: AVAudioSessionRouteDescription
    ) -> AVAudioSessionPortDescription? {
        route.outputs.first(where: {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }) ?? route.outputs.first
    }
}
#elseif os(macOS)
private struct AudioOutputRouteButton: View {
    var tintColor: Color = Color.white.opacity(0.7)

    var body: some View {
        AirPlayButton()
            .frame(width: 44, height: 44)
            .colorMultiply(tintColor)
            .accessibilityLabel("Audio output")
    }
}
#else
private struct AudioOutputRouteButton: View {
    var tintColor: Color = Color.white.opacity(0.7)

    var body: some View {
        Image(systemName: "airplayaudio")
            .font(.title3)
            .foregroundStyle(tintColor)
            .frame(width: 44, height: 44)
    }
}
#endif

// MARK: - Volume

struct VolumeSection: View {
    let contentColor: Color
    let secondaryContentColor: Color
    @Environment(\.appContainer) private var container
    #if os(macOS)
    @AppStorage("cassette.lastVolume") private var localVolume: Double = 0.7
    #endif

    var body: some View {
        HStack(spacing: CassetteSpacing.s) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryContentColor.opacity(0.85))
                .frame(width: 18)
                .accessibilityHidden(true)

            #if os(iOS)
            SystemVolumeView(contentColor: contentColor)
            #elseif os(macOS)
            Slider(
                value: Binding(
                    get: { localVolume },
                    set: { newValue in
                        localVolume = newValue
                        Task { await container?.playerService.setVolume(Float(newValue)) }
                    }
                ),
                in: 0...1
            )
            .tint(contentColor)
            .accessibilityLabel(String(localized: "Volume", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            #endif

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryContentColor.opacity(0.85))
                .frame(width: 22)
                .accessibilityHidden(true)
        }
    }
}
