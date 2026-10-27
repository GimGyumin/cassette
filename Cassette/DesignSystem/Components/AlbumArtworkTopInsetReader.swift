// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit

/// Read the window's status/camera safe area, excluding navigation-bar height.
struct AlbumArtworkTopInsetReader: UIViewRepresentable {
    var changed: (CGFloat) -> Void
    func makeUIView(context: Context) -> InsetView { InsetView() }
    func updateUIView(_ view: InsetView, context: Context) {
        view.changed = changed
        view.setNeedsLayout()
    }
    final class InsetView: UIView {
        var changed: ((CGFloat) -> Void)?
        private var lastInset: CGFloat?
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let inset = window.safeAreaInsets.top
            guard inset != lastInset else { return }
            lastInset = inset
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.changed?(inset)
            }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }
    }
}
#endif
