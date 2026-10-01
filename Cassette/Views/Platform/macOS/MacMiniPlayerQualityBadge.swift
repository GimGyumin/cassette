// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import AppKit
import SwiftUI

/// Compact lossless / Dolby mark for the macOS bottom mini player — Apple Music–style icon + popover.
struct MacMiniPlayerQualityBadge: View {
    let quality: AudioQualityKind

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            badgeIcon(height: 11)
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(quality.title)
        .accessibilityLabel(quality.title)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent
                .padding(16)
                .frame(width: 220)
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(spacing: 10) {
            badgeIcon(height: 22)
                .foregroundStyle(.primary)

            Text(quality.title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)

            Text(quality.detailLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showPopover = false
                UserDefaults.standard.set(
                    SettingsTab.playback.rawValue,
                    forKey: cassetteSettingsSelectedTabKey
                )
                DispatchQueue.main.async {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            } label: {
                Text("Audio Quality Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(CassetteColors.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func badgeIcon(height: CGFloat) -> some View {
        switch quality {
        case .dolbyAtmos, .dolby, .multichannel:
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: height, weight: .semibold))
                .accessibilityHidden(true)
        case .hiResLossless, .lossless:
            Image("AppleLosslessMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: height * 1.85, height: height)
                .accessibilityHidden(true)
        }
    }
}
#endif
