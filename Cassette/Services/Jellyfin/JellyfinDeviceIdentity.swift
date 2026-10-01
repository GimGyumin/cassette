// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated struct JellyfinDeviceIdentity: Sendable, Equatable {
    let id: String
    let name: String
    let clientName: String
    let clientVersion: String

    @MainActor
    static func current(defaults: UserDefaults = .standard) -> Self {
        let storageKey = "cassette.jellyfin.device-id"
        let id: String
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            id = existing
        } else {
            id = "cassette-\(UUID().uuidString.lowercased())"
            defaults.set(id, forKey: storageKey)
        }

        #if canImport(UIKit)
        let name = UIDevice.current.model
        #else
        let name = "Mac"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return Self(id: id, name: name, clientName: "Cassette", clientVersion: version)
    }
}
