// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Dark top gradient so light status-bar icons stay readable over dark immersive art
/// that bleeds under the safe area. Skipped on light pages (dark status icons).
struct StatusBarScrim: View {
    /// When `true`, page chrome is light → status bar uses dark content; no dark scrim.
    var isLightPage: Bool = false

    var body: some View {
        if isLightPage {
            Color.clear
        } else {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.55),
                        Color.black.opacity(0.28),
                        Color.black.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Older systems need a contrast fallback. Modern scroll views use the system soft edge.
    @ViewBuilder
    func cassetteStatusBarScrim(isLightPage: Bool = false, isEnabled: Bool = true) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
        } else {
            overlay {
                if isEnabled { StatusBarScrim(isLightPage: isLightPage) }
            }
        }
    }

    /// Applies status-bar / nav chrome color scheme for immersive detail pages.
    ///
    /// Modern systems own the bar background and soft edge. Older systems retain
    /// their visible-background contrast fallback for light artwork.
    @ViewBuilder
    func cassetteImmersiveStatusBar(
        colorScheme: ColorScheme?,
        scrolledChromeProgress: CGFloat = 0,
        floatingOverArtwork: Bool = false,
        statusBarColorScheme: ColorScheme? = nil,
        navigationBarColorScheme: ColorScheme? = nil
    ) -> some View {
        let statusScheme = statusBarColorScheme ?? colorScheme
        let navigationScheme = navigationBarColorScheme ?? statusScheme
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .toolbarBackgroundVisibility(floatingOverArtwork && scrolledChromeProgress == 0 ? .hidden : .automatic, for: .navigationBar)
                // The navigation controller owns status-bar appearance. Match its
                // scheme to the visible top artwork, independently of page content.
                .toolbarColorScheme(navigationScheme, for: .navigationBar)
                .background {
                    if let statusScheme {
                        StatusBarStyleBridge(style: statusScheme == .light ? .darkContent : .lightContent)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            let isLight = colorScheme == .light
            let isDark = colorScheme == .dark
            let showBar = isLight || scrolledChromeProgress > 0.05
            let fill: Color = {
                if isLight {
                    return Color.white.opacity(max(0.01, 0.55 * Double(scrolledChromeProgress)))
                }
                if isDark {
                    return Color.black.opacity(0.55 * Double(scrolledChromeProgress))
                }
                return Color.clear
            }()

            self
                .toolbarBackground(showBar ? .visible : .hidden, for: .navigationBar)
                .toolbarBackground(fill, for: .navigationBar)
                .toolbarColorScheme(navigationScheme, for: .navigationBar)
                .background {
                    if let statusScheme {
                        StatusBarStyleBridge(style: statusScheme == .light ? .darkContent : .lightContent)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Best-effort status-bar style nudge when the hosting navigation controller asks children.
private struct StatusBarStyleBridge: UIViewControllerRepresentable {
    var style: UIStatusBarStyle

    func makeUIViewController(context: Context) -> StatusBarHostingController {
        let controller = StatusBarHostingController()
        controller.statusBarStyle = style
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ uiViewController: StatusBarHostingController, context: Context) {
        uiViewController.statusBarStyle = style
    }
}

private final class StatusBarHostingController: UIViewController {
    var statusBarStyle: UIStatusBarStyle = .default {
        didSet {
            setNeedsStatusBarAppearanceUpdate()
            parent?.setNeedsStatusBarAppearanceUpdate()
            navigationController?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        parent?.setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }
}
#endif
