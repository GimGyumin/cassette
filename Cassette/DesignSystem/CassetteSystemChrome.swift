// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Keeps brand chrome (tabs, CTAs) on Cassette Red while system alerts and action sheets
/// follow Apple’s semantic colors for readable contrast.
enum CassetteSystemChrome {
    static func configure() {
        #if os(iOS)
        // WindowGroup brand tint paints Cancel red. Isolate alerts and tint Cancel with
        // label color (white on dark sheets, black on light); `.destructive` stays systemRed.
        let cancelTint = UIColor.label
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = cancelTint
        UILabel.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = cancelTint
        #endif
    }

    /// Tint for non-destructive alert actions (Cancel). Uses label color so Cancel reads
    /// white on dark alert sheets and black on light ones — only `.destructive` stays red.
    static var alertActionTint: Color {
        #if os(iOS)
        Color(uiColor: .label)
        #elseif os(macOS)
        Color(nsColor: .labelColor)
        #else
        .primary
        #endif
    }
}

extension View {
    /// Destructive confirmation under Cassette’s red accent:
    /// Cancel → label color (white on dark alerts), destructive → system red.
    ///
    /// Hosts the alert on a clear background with an isolated label tint so the
    /// WindowGroup brand tint does not paint Cancel red (Cancel → white/black label,
    /// destructive → system red).
    func cassetteDestructiveAlert(
        _ title: LocalizedStringResource,
        isPresented: Binding<Bool>,
        message: LocalizedStringResource,
        destructiveButtonTitle: LocalizedStringResource = "Remove",
        cancelButtonTitle: LocalizedStringResource = "Cancel",
        onDestructive: @escaping () -> Void
    ) -> some View {
        background {
            Color.clear
                .alert(title, isPresented: isPresented) {
                    Button(destructiveButtonTitle, role: .destructive, action: onDestructive)
                    Button(cancelButtonTitle, role: .cancel) {}
                } message: {
                    Text(message)
                }
                .tint(CassetteSystemChrome.alertActionTint)
        }
    }

    /// String convenience for dynamic titles (e.g. count-based confirmations).
    func cassetteDestructiveAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String,
        destructiveButtonTitle: String = String(localized: "Remove", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
        cancelButtonTitle: String = String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
        onDestructive: @escaping () -> Void
    ) -> some View {
        background {
            Color.clear
                .alert(title, isPresented: isPresented) {
                    Button(destructiveButtonTitle, role: .destructive, action: onDestructive)
                    Button(cancelButtonTitle, role: .cancel) {}
                } message: {
                    Text(message)
                }
                .tint(CassetteSystemChrome.alertActionTint)
        }
    }

    /// Isolates `.tint` for any alert / confirmationDialog attached in `alerts`.
    func cassetteSystemAlertTint<Alerts: View>(@ViewBuilder alerts: () -> Alerts) -> some View {
        background {
            alerts()
                .tint(CassetteSystemChrome.alertActionTint)
        }
    }
}
