// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import UIKit

/// iPhone rotates only while Now Playing is presented; iPad supports both directions.
/// Also reconnects the background download session when the system relaunches the app.
final class CassetteAppDelegate: NSObject, UIApplicationDelegate {
    private(set) var isFullPlayerPresented = false
    private var portraitReturnTask: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationCenter.default.addObserver(self, selector: #selector(playerPresentationChanged(_:)),
            name: .cassetteFullPlayerPresentationChanged, object: nil)
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == CassetteBackgroundDownloads.artworkSessionIdentifier {
            CassetteBackgroundDownloads.artwork.prepareForBackgroundEvents {
                CassetteApp.scheduleLibraryPreparation()
                completionHandler()
            }
            return
        }
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
        if UIDevice.current.userInterfaceIdiom == .pad { return .allButUpsideDown }
        return isFullPlayerPresented ? .allButUpsideDown : .portrait
    }

    @objc private func playerPresentationChanged(_ notification: Notification) {
        guard let presented = notification.userInfo?["isPresented"] as? Bool else { return }
        setFullPlayerPresented(presented)
    }

    func setFullPlayerPresented(_ presented: Bool) {
        portraitReturnTask?.cancel()
        if presented {
            isFullPlayerPresented = true
            updateOrientationSupport(returnToPortrait: false)
        } else {
            // Called by fullScreenCover's actual dismissal completion, after its zoom
            // layer is gone. Reopening cancels the pending portrait request.
            portraitReturnTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                isFullPlayerPresented = false
                updateOrientationSupport(returnToPortrait: true)
            }
        }
    }

    private func updateOrientationSupport(returnToPortrait: Bool) {
        guard !ProcessInfo.processInfo.isiOSAppOnMac,
              UIDevice.current.userInterfaceIdiom == .phone else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene.activationState == .foregroundActive {
            guard let root = scene.keyWindow?.rootViewController else { continue }
            root.setNeedsUpdateOfSupportedInterfaceOrientations()
            var top = root
            while let presented = top.presentedViewController {
                presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                top = presented
            }
            if returnToPortrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                    // A scene may have backgrounded while dismissal was finishing.
                    // The portrait-only mask remains in force for its next activation.
                    _ = error
                }
            }
        }
    }
}
#endif
