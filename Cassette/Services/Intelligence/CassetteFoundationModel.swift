// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Shared Apple Intelligence entry point using the on-device system model only.
///
/// Do **not** touch `PrivateCloudComputeLanguageModel`: without the managed
/// `com.apple.developer.private-cloud-compute` entitlement, merely probing it
/// fatals (`FoundationModels/ErrorConversion.swift`) and freezes the Song Info sheet.
@available(iOS 26.0, macOS 26.0, *)
enum CassetteFoundationModel {
    /// True when the on-device Apple Intelligence model can run.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    static func makeSession(instructions: String? = nil) -> LanguageModelSession {
        if let instructions, !instructions.isEmpty {
            return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        }
        return LanguageModelSession(model: SystemLanguageModel.default)
    }

    /// Prefer low temperature for factual song blurbs / lyric readings.
    static var groundedOptions: GenerationOptions {
        var options = GenerationOptions()
        options.temperature = 0.2
        return options
    }
}
#endif
