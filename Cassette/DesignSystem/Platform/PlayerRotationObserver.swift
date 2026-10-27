// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit

/// The window performs the actual rotation. Only suspend decorative SwiftUI
/// animations until its coordinator completes, including cancelled rotations.
struct PlayerRotationObserver: UIViewControllerRepresentable {
    var changed: (Bool) -> Void
    func makeUIViewController(context: Context) -> PlayerRotationController {
        PlayerRotationController(changed: changed)
    }
    func updateUIViewController(_ controller: PlayerRotationController, context: Context) {
        controller.changed = changed
    }
}

final class PlayerRotationController: UIViewController {
    var changed: (Bool) -> Void
    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        changed(true)
        super.viewWillTransition(to: size, with: coordinator)
        // Capture the callback: SwiftUI may replace this controller during rotation.
        // A weak controller would leave isRotating true and disable all later animations.
        let completion = changed
        let scheduled = coordinator.animate(alongsideTransition: nil) { _ in
            completion(false)
        }
        if !scheduled { changed(false) }
    }
}
#endif
