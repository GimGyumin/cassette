import Foundation

/// Separate offsets are required: artists, albums and songs have different result counts.
nonisolated struct SearchPageRequest: Sendable {
    var artistOffset = 0
    var albumOffset = 0
    var songOffset = 0
    var artistCount = 50
    var albumCount = 50
    var songCount = 50
}
