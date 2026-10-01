// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import Combine
import MediaAccessibility
import OSLog
import UIKit

/// Integrates with system Music Haptics (Settings → Accessibility → Music Haptics).
/// Custom CHHapticEngine playback is intentionally not used — Apple drives haptics from
/// Now Playing ISRC + `MusicHapticsSupported` in Info.plist.
@MainActor
final class MusicHapticsController: ObservableObject {
    static let shared = MusicHapticsController()

    @Published private(set) var isSystemActive = false
    private var observer: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var statusObserverToken: (any NSCopying)?
    private var observersInstalled = false
    /// Refresh once when returning from background (skipped XPC while suspended).
    private var needsForegroundRefresh = false

    private init() {}

    private func installObserversIfNeeded() {
        guard !observersInstalled, AppleMusicSettings.shared.musicHapticsEnabled else { return }
        observersInstalled = true
        observer = NotificationCenter.default.addObserver(
            forName: MAMusicHapticsManager.activeStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.needsForegroundRefresh else { return }
                self.needsForegroundRefresh = false
                self.refresh()
            }
        }
        // Prefer the status observer over checkHapticTrackAvailability — the latter often
        // returns false early / hits sandbox 159 while haptics still attach later.
        statusObserverToken = MAMusicHapticsManager.shared.addStatusObserver { [weak self] isrc, active in
            Logger.player.info(
                "Music Haptics status isrc=\(isrc, privacy: .public) active=\(active, privacy: .public)"
            )
            Task { @MainActor [weak self] in
                self?.isSystemActive = active
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let statusObserverToken {
            MAMusicHapticsManager.shared.removeStatusObserver(statusObserverToken)
        }
    }

    var isSupportedByHardware: Bool {
        true
    }

    /// User preference (Settings) AND system Accessibility toggle.
    var shouldEngage: Bool {
        AppleMusicSettings.shared.musicHapticsEnabled && isSystemActive
    }

    /// System Music Haptics XPC is sandbox-blocked in true background (error 159).
    private var isAppBackgrounded: Bool {
        UIApplication.shared.applicationState == .background
    }

    func refresh() {
        guard AppleMusicSettings.shared.musicHapticsEnabled else {
            isSystemActive = false
            return
        }
        installObserversIfNeeded()
        guard !isAppBackgrounded else {
            needsForegroundRefresh = true
            return
        }
        let wasActive = isSystemActive
        isSystemActive = MAMusicHapticsManager.shared.isActive
        if wasActive != isSystemActive {
            Logger.player.debug("Music Haptics system active=\(self.isSystemActive)")
        }
    }

    /// Kept for call-site compatibility; system Music Haptics follows Now Playing + user Settings.
    func setPlaying(_ playing: Bool) {
        guard AppleMusicSettings.shared.musicHapticsEnabled else {
            isSystemActive = false
            return
        }
        installObserversIfNeeded()
        guard !isAppBackgrounded else {
            needsForegroundRefresh = true
            return
        }
        refresh()
        guard shouldEngage, playing else { return }
        Logger.player.debug("Music Haptics: playback active (system manages haptics when enabled)")
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
#endif
