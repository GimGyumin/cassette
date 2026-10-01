// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftUI

/// Progressive karaoke highlight for songLyrics v2 `cue` byte ranges.
enum LyricKaraokeText {
    private static let inactiveColor = Color.white.opacity(0.30)
    private static let currentPendingColor = Color.white.opacity(0.34)
    private static let activeColor = Color.white

    static func attributed(
        _ text: String,
        activeThroughByteEnd: Int?,
        isCurrent: Bool,
        followsPlayback: Bool,
        fontSize: CGFloat
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = Font.system(size: fontSize, weight: .heavy)

        guard followsPlayback else {
            attributed.foregroundColor = Color.white.opacity(0.88)
            return attributed
        }

        guard isCurrent else {
            attributed.foregroundColor = inactiveColor
            return attributed
        }

        guard let byteEnd = activeThroughByteEnd, byteEnd >= 0 else {
            attributed.foregroundColor = activeColor
            return attributed
        }

        let endStringIndex = indexAfterInclusiveUTF8ByteEnd(byteEnd, in: text)
        guard endStringIndex > text.startIndex else {
            attributed.foregroundColor = activeColor
            return attributed
        }

        // Resolve AttributedString indices *after* whole-string color mutation — stale
        // indices from before a mutation can invert `start..<end` and trap.
        attributed.foregroundColor = currentPendingColor
        guard let attrEnd = AttributedString.Index(endStringIndex, within: attributed),
              attributed.startIndex < attrEnd else {
            attributed.foregroundColor = activeColor
            return attributed
        }
        attributed[attributed.startIndex..<attrEnd].foregroundColor = activeColor
        return attributed
    }

    /// Joins background word texts, stripping parentheses, for chorus display.
    static func chorusText(from words: [LyricDisplayWord]) -> String {
        words
            .map { $0.text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Index just after the character that contains the inclusive UTF-8 `byteEnd`.
    private static func indexAfterInclusiveUTF8ByteEnd(_ byteEnd: Int, in string: String) -> String.Index {
        var utf8Offset = 0
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            utf8Offset += string.utf8.distance(from: index, to: next)
            index = next
            if utf8Offset > byteEnd {
                return index
            }
        }
        return string.endIndex
    }
}
