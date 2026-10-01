// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Best-effort handoff into Apple Passwords after a successful first sign-in.
///
/// Cassette always stores credentials in the app Keychain. For arbitrary Subsonic hosts we cannot
/// claim Associated Domains, so the system “Save Password?” sheet (driven by `.username` /
/// `.password` / `.URL` text content types on the sign-in form) is the supported path into the
/// Passwords app. Call this while the login fields are still on screen.
enum PasswordAutoFillOffer {
    /// Resign the keyboard so Password AutoFill can present Save Password before navigation.
    @MainActor
    static func offerSaveAfterSuccessfulLogin() async {
        #if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        // Keep the sign-in form mounted briefly so iOS can associate the URL / username / password
        // fields and present Save Password.
        try? await Task.sleep(for: .milliseconds(800))
        #endif
    }
}
