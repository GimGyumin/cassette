// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
@testable import Cassette

@Suite("LyricTranslationBundler")
struct LyricTranslationBundlerTests {

    @Test func makeBundles_skipsBlanks_andWindowsBySize() {
        let lyrics = [
            "one",
            "",
            "two",
            "three",
            "   ",
            "four",
            "five",
            "six"
        ]
        let bundles = LyricTranslationBundler.makeBundles(from: lyrics, bundleSize: 3)
        #expect(bundles.count == 2)
        #expect(bundles[0].indices == [0, 2, 3])
        #expect(bundles[0].originalLines == ["one", "two", "three"])
        #expect(bundles[1].indices == [5, 6, 7])
        #expect(bundles[1].joinedText == "four\nfive\nsix")
    }

    @Test func distribute_prefersMatchingNewlineCount() {
        let originals = ["a line", "b line", "c line"]
        let parts = LyricTranslationBundler.distribute(
            translated: "하나\n둘\n셋",
            onto: originals
        )
        #expect(parts == ["하나", "둘", "셋"])
    }

    @Test func distribute_proportionalFallback_whenLineCountMismatches() {
        let originals = ["short", "a much longer original line here"]
        let parts = LyricTranslationBundler.distribute(
            translated: "짧은 번역과 더 긴 번역 문장이 이어진 결과",
            onto: originals
        )
        #expect(parts.count == 2)
        #expect(!parts[0].isEmpty)
        #expect(!parts[1].isEmpty)
        #expect(parts[0].count <= parts[1].count)
    }

    @Test func apply_writesBackByIndex_leavesBlanks() {
        let lyrics = ["one", "", "two", "three"]
        let bundles = LyricTranslationBundler.makeBundles(from: lyrics, bundleSize: 5)
        let result = LyricTranslationBundler.apply(
            bundles: bundles,
            translatedBlocks: ["하나\n둘\n셋"],
            into: lyrics
        )
        #expect(result == ["하나", "", "둘", "셋"])
    }
}
