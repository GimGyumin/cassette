// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension View {
    /// Shared wording and semantic roles; presentation and action colors belong to the system.
    func cassetteDestructiveAlert(
        _ title: LocalizedStringResource,
        isPresented: Binding<Bool>,
        message: LocalizedStringResource,
        destructiveButtonTitle: LocalizedStringResource = "Remove",
        cancelButtonTitle: LocalizedStringResource = "Cancel",
        onDestructive: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(destructiveButtonTitle, role: .destructive, action: onDestructive)
            Button(cancelButtonTitle, role: .cancel) {}
        } message: {
            Text(message)
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
        alert(title, isPresented: isPresented) {
            Button(destructiveButtonTitle, role: .destructive, action: onDestructive)
            Button(cancelButtonTitle, role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    /// Hosts multiple independently presented system confirmations.
    func cassetteSystemAlertTint<Alerts: View>(@ViewBuilder alerts: () -> Alerts) -> some View {
        background {
            alerts()
        }
    }
}
