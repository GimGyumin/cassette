// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import UIKit

/// Interface orientation: iPhone + iPad → all but upside-down; iOS-on-Mac → portrait.
/// Also reconnects the background download session when the system relaunches the app.
final class CassetteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CassetteSystemChrome.configure()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == CassetteBackgroundDownloads.sessionIdentifier else {
            completionHandler()
            return
        }
        CassetteBackgroundDownloads.shared.prepareForBackgroundEvents(completionHandler: completionHandler)
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // "Designed for iPhone/iPad" on Mac — keep portrait (windowed Catalyst-style).
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return .portrait
        }
        // iPad: allow landscape Now Playing / shelves (FullPlayer adapts via size class).
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .allButUpsideDown
        }
        // iPhone: portrait only.
        return .portrait
    }
}
#endif
