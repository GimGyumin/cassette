// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Coordinates cold-start network so Home can claim the server first.
/// Discover / Library / session restore wait here instead of stampeding `getAlbumList2`.
@MainActor
enum AppBootGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) static var homeReady = false
    private static var waiters: [Waiter] = []

    static func markHomeReady() {
        homeReady = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.continuation.resume()
        }
    }

    /// Resets between tests / server switches. Parked waiters time out on their own.
    static func reset() {
        homeReady = false
    }

    /// Waits until Home marks ready. Timeout is a safety valve (no-server / stuck Home);
    /// keep it above the Subsonic request timeout so waiters don't stampede mid-fetch.
    static func waitForHome(timeout: Duration = .seconds(45)) async {
        if homeReady { return }

        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if homeReady {
                continuation.resume()
                return
            }
            waiters.append(Waiter(id: id, continuation: continuation))
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume()
            }
        }
    }
}
