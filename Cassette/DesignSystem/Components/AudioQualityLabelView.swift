import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AudioQualityLabelView: View {
    enum Style {
        /// Player scrubber: compact rounded-rectangle chip.
        case pill
        /// Album header: Apple Music–style mark + title, no capsule.
        case album
    }

    let quality: AudioQualityKind
    var foreground: Color = .primary
    /// When false, renders plain label text (no glass capsule, padding, or detail sheet).
    var interactive: Bool = true
    /// Player scrubber: flat fill only — never Liquid Glass.
    var usesGlass: Bool = false
    var style: Style = .pill
    var compact: Bool = false

    @State private var showDetail = false

    var body: some View {
        switch style {
        case .album:
            albumMark
                .foregroundStyle(foreground)
                .accessibilityLabel(quality.title)
        case .pill:
            if interactive {
                Button {
                    // Disable the system presentation slide-up; the card animates from center.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        showDetail = true
                    }
                } label: {
                    pillContent
                        .foregroundStyle(foreground)
                        .padding(.horizontal, compact ? 7 : 10)
                        .padding(.vertical, compact ? 4 : 6)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(foreground.opacity(compact ? 0.16 : (usesGlass ? 0.18 : 0.22)))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .cassetteFullScreenCover(isPresented: $showDetail) {
                    AudioQualityDetailOverlay(quality: quality, isPresented: $showDetail)
                        .presentationBackground(.clear)
                }
                #elseif os(macOS)
                .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                    MacAudioQualityPopover(quality: quality, isPresented: $showDetail)
                }
                #endif
            } else {
                pillContent
                    .foregroundStyle(foreground)
            }
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        switch quality {
        case .dolbyAtmos, .dolby, .multichannel:
            HStack(spacing: 6) {
                AudioFormatSymbol(quality: quality, height: 10)
                Text(quality.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        case .hiResLossless, .lossless:
            HStack(spacing: 6) {
                losslessMark(height: 10)
                Text(quality.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var albumMark: some View {
        switch quality {
        case .dolbyAtmos, .dolby, .multichannel:
            HStack(spacing: 4) {
                AudioFormatSymbol(quality: quality, height: 9)
                Text(quality.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
        case .hiResLossless, .lossless:
            HStack(spacing: 4) {
                losslessMark(height: 9)
                Text(quality.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
        }
    }

    /// Fixed aspect so the wide ALAC mark can’t steal HStack width and wrap the title.
    private func losslessMark(height: CGFloat) -> some View {
        Image("AppleLosslessMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: height * 1.85, height: height)
            .accessibilityHidden(true)
    }
}

#if os(macOS)
/// A native popover avoids creating a second transparent sheet window behind the quality card.
private struct MacAudioQualityPopover: View {
    let quality: AudioQualityKind
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: CassetteSpacing.m) {
            switch quality {
            case .dolbyAtmos, .dolby, .multichannel:
                AudioFormatSymbol(quality: quality, height: 26)
            case .hiResLossless, .lossless:
                Image("AppleLosslessMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 26)
            }

            Text(quality.title)
                .font(.headline)

            Text(quality.detailLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Audio Quality Settings") {
                UserDefaults.standard.set(
                    SettingsTab.playback.rawValue,
                    forKey: cassetteSettingsSelectedTabKey
                )
                isPresented = false
                DispatchQueue.main.async {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(CassetteColors.accent)
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 300)
    }
}
#endif

/// Centered card — Apple alert–style scale + fade (not a bottom sheet).
private struct AudioQualityDetailOverlay: View {
    let quality: AudioQualityKind
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var dragOffset: CGFloat = 0

    private var dismissAnimation: Animation {
        CassetteAnimation.dismiss(reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack {
            // Slight dim only — the player stays visible behind the centered card
            // instead of being covered by a full-screen material blur.
            Color.black.opacity(0.3)
                .opacity(appeared ? 1 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                Group {
                    switch quality {
                    case .dolbyAtmos, .dolby, .multichannel:
                        AudioFormatSymbol(quality: quality, height: 42)
                    case .hiResLossless, .lossless:
                        Image("AppleLosslessMark")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 76, height: 42)
                    }
                }
                .foregroundStyle(Color.white.opacity(0.62))
                .padding(.top, CassetteSpacing.s)
                .padding(.bottom, 36)

                Text(quality.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, CassetteSpacing.xs)

                Text(quality.detailLine)
                    .font(.body.weight(.regular))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, CassetteSpacing.l)

                Button {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #elseif os(macOS)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    #endif
                } label: {
                    Text("Audio Quality Settings")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .cassettePlainCapsule(fill: Color.white.opacity(0.16))
                }
                .buttonStyle(.plain)
                .padding(.bottom, CassetteSpacing.s)

                Button {
                    dismiss()
                } label: {
                    Text("OK")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .cassettePlainCapsule(fill: .white)
                }
                .buttonStyle(.plain)
            }
            .padding(CassetteSpacing.xl)
            .frame(maxWidth: 320)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.black.opacity(0.22))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
            }
            .shadow(color: .black.opacity(0.34), radius: 30, y: 14)
            .padding(.horizontal, 30)
            .offset(y: dragOffset)
            // Apple alert: start slightly large + faded, spring into place.
            .scaleEffect(appeared ? 1.0 : (reduceMotion ? 1.0 : 1.14))
            .opacity(appeared ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        if value.translation.height > 80 || value.predictedEndTranslation.height > 200 {
                            dismiss()
                        } else {
                            withAnimation(CassetteAnimation.present(reduceMotion: reduceMotion)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(CassetteAnimation.present(reduceMotion: reduceMotion)) {
                appeared = true
            }
        }
    }

    private func dismiss() {
        withAnimation(dismissAnimation) {
            appeared = false
            dragOffset = 0
        }
        let delay = reduceMotion ? 0.15 : 0.22
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPresented = false
            }
        }
    }
}
