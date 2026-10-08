// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared controller that lets a detail page (album/playlist/artist) push its cover-derived
/// light/dark appearance up to the root chrome — tab bar and mini player — so their text /
/// glyphs flip to white or black to match the currently visible artwork page.
///
/// Detail pages write an override while visible and clear it on disappear; everything else
/// reads `overrideColorScheme ?? system colorScheme`.
@MainActor
@Observable
final class ChromeAppearance {
    /// Non-nil only while a themed detail page is frontmost and wants a forced scheme.
    private var owners: [(id: UUID, scheme: ColorScheme?)] = []
    var overrideColorScheme: ColorScheme? { owners.last?.scheme }

    func appear(id: UUID, scheme: ColorScheme?) {
        guard owners.last?.id != id || owners.last?.scheme != scheme else { return }
        owners.removeAll { $0.id == id }
        owners.append((id, scheme))
    }

    func update(id: UUID, scheme: ColorScheme?) {
        guard let index = owners.firstIndex(where: { $0.id == id }) else { return }
        guard owners[index].scheme != scheme else { return }
        owners[index].scheme = scheme
    }

    func disappear(id: UUID) {
        guard owners.contains(where: { $0.id == id }) else { return }
        owners.removeAll { $0.id == id }
    }
}

extension View {
    /// Pushes a themed detail page's `preferredColorScheme` into the shared
    /// `ChromeAppearance` while visible, restoring the previous override on disappear.
    func chromeAppearance(_ scheme: ColorScheme?) -> some View {
        modifier(ThemedChromeSchemeModifier(scheme: scheme))
    }
}

private struct ThemedChromeSchemeModifier: ViewModifier {
    let scheme: ColorScheme?
    @Environment(ChromeAppearance.self) private var chromeAppearance
    @State private var ownerID = UUID()

    func body(content: Content) -> some View {
        #if os(iOS)
        content.background {
            ChromeAppearanceLifecycle(appearance: chromeAppearance, ownerID: ownerID, scheme: scheme)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        content
            .onAppear { chromeAppearance.appear(id: ownerID, scheme: scheme) }
            .onChange(of: scheme) { _, newValue in
                // The cover color resolves asynchronously (initially .clear → nil scheme);
                // push the real light/dark as soon as it lands so mini player / tab chrome
                // re-render with the correct glyph ink.
                chromeAppearance.update(id: ownerID, scheme: newValue)
            }
            .onDisappear {
                chromeAppearance.disappear(id: ownerID)
            }
        #endif
    }
}

#if os(iOS)
/// SwiftUI onAppear runs for the revealed page before an interactive pop commits.
/// Publishing root TabView chrome then can invalidate the transition in progress.
/// UIKit's completed appearance callbacks also distinguish a cancelled pop correctly.
private struct ChromeAppearanceLifecycle: UIViewControllerRepresentable {
    let appearance: ChromeAppearance
    let ownerID: UUID
    let scheme: ColorScheme?

    func makeUIViewController(context: Context) -> ChromeAppearanceController {
        ChromeAppearanceController(appearance: appearance, ownerID: ownerID, scheme: scheme)
    }

    func updateUIViewController(_ controller: ChromeAppearanceController, context: Context) {
        controller.update(scheme: scheme)
    }

    static func dismantleUIViewController(_ controller: ChromeAppearanceController, coordinator: ()) {
        controller.releaseAppearance()
    }
}

private final class ChromeAppearanceController: UIViewController {
    private let appearance: ChromeAppearance
    private let ownerID: UUID
    private var scheme: ColorScheme?
    private var isVisible = false
    private var isLeaving = false

    init(appearance: ChromeAppearance, ownerID: UUID, scheme: ColorScheme?) {
        self.appearance = appearance
        self.ownerID = ownerID
        self.scheme = scheme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewWillDisappear(_ animated: Bool) {
        isLeaving = true
        super.viewWillDisappear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        isLeaving = false
        appearance.appear(id: ownerID, scheme: scheme)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        releaseAppearance()
    }

    func update(scheme: ColorScheme?) {
        guard self.scheme != scheme else { return }
        self.scheme = scheme
        guard isVisible, !isLeaving else { return }
        // updateUIViewController runs inside SwiftUI's update transaction. Publish later,
        // and recheck visibility in case an interactive transition started meanwhile.
        Task { @MainActor [weak self] in
            guard let self, isVisible, !isLeaving else { return }
            appearance.update(id: ownerID, scheme: self.scheme)
        }
    }

    func releaseAppearance() {
        isVisible = false
        appearance.disappear(id: ownerID)
    }
}
#endif
