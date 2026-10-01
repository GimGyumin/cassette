// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Coordinates Siri cold starts.
///
/// App Intents may run before `AppContainer` has finished loading the persisted
/// server (a Siri launch can wake the process and run `perform()` while the
/// boot task is still mid-flight). The catalog waits here so a request made the
/// instant the app launches still sees the active server instead of an empty
/// result, while the timeout guarantees a cold start never deadlocks.
@MainActor
enum SiriBootGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private static var ready = false
    private static var waiters: [Waiter] = []

    static func markReady() {
        ready = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.continuation.resume()
        }
    }

    static func reset() {
        ready = false
    }

    static func waitUntilReady(timeout: Duration = .seconds(10)) async {
        if ready { return }

        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if ready {
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
