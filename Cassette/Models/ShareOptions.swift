// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

struct ShareOptions: Sendable {
    var description: String?
    var allowDownloads: Bool = false
    var shareOriginal: Bool = false
    var expires: Date? = nil
}
