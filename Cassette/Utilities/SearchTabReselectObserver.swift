// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit

/// Observes re-taps on the Search tab without replacing `UITabBarController.delegate`
/// (hijacking that delegate breaks SwiftUI `TabView` selection — e.g. Library bouncing to Home).
struct SearchTabReselectObserver: UIViewControllerRepresentable {
    var onSearchReselect: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        context.coordinator.onSearchReselect = onSearchReselect
        context.coordinator.attachIfNeeded(from: controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.onSearchReselect = onSearchReselect
        context.coordinator.attachIfNeeded(from: uiViewController)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        var onSearchReselect: (() -> Void)?
        private weak var tabBar: UITabBar?
        private var tapRecognizer: UITapGestureRecognizer?
        private var lastSelectedIndex: Int?

        override init() {
            super.init()
        }

        func attachIfNeeded(from host: UIViewController) {
            Task { @MainActor [weak self, weak host] in
                guard let self, let host else { return }
                guard let tab = Self.findTabBarController(from: host) else { return }
                let bar = tab.tabBar
                guard self.tabBar !== bar else { return }

                if let old = self.tapRecognizer {
                    self.tabBar?.removeGestureRecognizer(old)
                }

                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                recognizer.cancelsTouchesInView = false
                bar.addGestureRecognizer(recognizer)

                self.tabBar = bar
                self.tapRecognizer = recognizer
                self.lastSelectedIndex = tab.selectedIndex
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let bar = tabBar,
                  let items = bar.items,
                  !items.isEmpty
            else { return }

            let x = recognizer.location(in: bar).x
            let width = bar.bounds.width / CGFloat(items.count)
            guard width > 0 else { return }
            let index = min(items.count - 1, max(0, Int(x / width)))

            // Search uses `Tab(..., role: .search)` and sits on the trailing edge.
            let isSearch = index == items.count - 1
            if isSearch, lastSelectedIndex == index {
                onSearchReselect?()
            }
            lastSelectedIndex = index
        }

        @MainActor
        private static func findTabBarController(from host: UIViewController) -> UITabBarController? {
            var responder: UIResponder? = host
            while let current = responder {
                if let tab = current as? UITabBarController { return tab }
                responder = current.next
            }
            var parent = host.parent
            while let current = parent {
                if let tab = current as? UITabBarController { return tab }
                parent = current.parent
            }
            guard let root = host.view.window?.rootViewController else { return nil }
            return findInHierarchy(root)
        }

        @MainActor
        private static func findInHierarchy(_ root: UIViewController) -> UITabBarController? {
            if let tab = root as? UITabBarController { return tab }
            for child in root.children {
                if let found = findInHierarchy(child) { return found }
            }
            if let presented = root.presentedViewController {
                return findInHierarchy(presented)
            }
            return nil
        }
    }
}
#endif
