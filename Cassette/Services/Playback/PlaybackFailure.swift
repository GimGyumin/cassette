import AVFoundation
import AudioStreaming
import Foundation
import SwiftSonic

/// Value-only diagnostics: retain the domain/code, never a request URL or credential payload.
nonisolated struct PlaybackFailure: Error, Sendable, Equatable, LocalizedError {
    enum Kind: Sendable, Equatable { case network, authorization, missingMedia, decoding, unsupported, session, cancelled, unknown }
    let kind: Kind
    let domain: String
    let code: Int

    static func classify(_ error: Error?, httpStatus: Int? = nil, depth: Int = 0) -> Self {
        if httpStatus == 401 || httpStatus == 403 { return .init(kind: .authorization, domain: "HTTP", code: httpStatus!) }
        if httpStatus == 404 || httpStatus == 410 { return .init(kind: .missingMedia, domain: "HTTP", code: httpStatus!) }
        if let status = httpStatus, status == 408 || status == 429 || (500...599).contains(status) {
            return .init(kind: .network, domain: "HTTP", code: status)
        }
        if let status = httpStatus, status >= 400 { return .init(kind: .unknown, domain: "HTTP", code: status) }
        if error is CancellationError { return .init(kind: .cancelled, domain: "Swift.Task", code: 0) }
        if let failure = error as? Self { return failure }
        guard let error else { return .init(kind: .unknown, domain: "Playback", code: 0) }
        if let http = error as? HTTPTransferFailure { return classify(nil, httpStatus: http.statusCode) }
        if let error = error as? CassetteError {
            switch error {
            case .playbackFailed(let failure): return failure
            case .connectionFailed(let underlying), .downloadFailed(_, let underlying), .cacheStorageFailed(let underlying):
                if depth < 4 { return classify(underlying, depth: depth + 1) }
            case .credentialsMissing, .keychainReadFailed: return .init(kind: .authorization, domain: "Cassette.Account", code: 0)
            case .mediaNotFound, .offlineUnavailable: return .init(kind: .missingMedia, domain: "Cassette.Media", code: 0)
            case .timeout: return classify(URLError(.timedOut))
            case .playbackMethodUnavailable: return .init(kind: .unsupported, domain: "Cassette.Route", code: 0)
            default: break
            }
        }
        if let error = error as? SwiftSonicError {
            switch error {
            case .network(let underlying): return classify(underlying)
            case .httpError(let status, _, _): return classify(nil, httpStatus: status)
            case .rateLimited: return classify(nil, httpStatus: 429)
            case .api(let api):
                let code = api.code.rawValue
                let kind: Kind = (40...60).contains(code) ? .authorization : (code == 70 ? .missingMedia : .unknown)
                return .init(kind: kind, domain: "OpenSubsonic", code: code)
            case .decoding: return .init(kind: .decoding, domain: "SwiftSonic.Response", code: 0)
            case .invalidConfiguration, .insecureRedirect: return .init(kind: .authorization, domain: "SwiftSonic.Configuration", code: 0)
            }
        }
        if let error = error as? JellyfinClientError {
            switch error {
            case .authenticationRequired, .missingAuthenticatedUser: return classify(nil, httpStatus: 401)
            case .unavailable(let status): return classify(nil, httpStatus: status)
            case .malformedResponse: return .init(kind: .decoding, domain: "Jellyfin.Response", code: 0)
            default: break
            }
        }
        if let error = error as? AudioPlayerError {
            switch error {
            case .networkError(.failure(let underlying)): return classify(underlying, depth: depth + 1)
            case .networkError: return .init(kind: .network, domain: "AudioStreaming.Network", code: 0)
            case .streamParseBytesFailure: return .init(kind: .decoding, domain: "AudioStreaming.Parser", code: 0)
            case .codecError: return .init(kind: .unsupported, domain: "AudioStreaming.Codec", code: 0)
            case .dataNotFound: return .init(kind: .missingMedia, domain: "AudioStreaming.Data", code: 0)
            case .audioSystemError: return .init(kind: .session, domain: "AudioStreaming.System", code: 0)
            case .other: return .init(kind: .unknown, domain: "AudioStreaming", code: 0)
            }
        }
        let ns = error as NSError
        if depth < 4, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let failure = classify(underlying, depth: depth + 1)
            if failure.kind != .unknown { return failure }
        }
        let kind: Kind
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case URLError.cancelled.rawValue: kind = .cancelled
            case URLError.userAuthenticationRequired.rawValue, URLError.userCancelledAuthentication.rawValue: kind = .authorization
            case URLError.fileDoesNotExist.rawValue, URLError.resourceUnavailable.rawValue: kind = .missingMedia
            case URLError.cannotDecodeContentData.rawValue, URLError.cannotDecodeRawData.rawValue: kind = .decoding
            case URLError.unsupportedURL.rawValue: kind = .unsupported
            default: kind = .network
            }
        } else if ns.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: ns.code) {
            case .decoderNotFound, .fileFormatNotRecognized: kind = .unsupported
            case .decodeFailed, .invalidSourceMedia: kind = .decoding
            case .decoderTemporarilyUnavailable: kind = .session
            #if os(iOS)
            case .mediaServicesWereReset, .sessionWasInterrupted: kind = .session
            #endif
            default: kind = .unknown
            }
        } else { kind = .unknown }
        return .init(kind: kind, domain: ns.domain, code: ns.code)
    }

    var errorDescription: String? {
        switch kind {
        case .network: String(localized: "Audio could not be loaded. Check your connection and try again.")
        case .authorization: String(localized: "The server denied access to this audio. Check your account credentials.")
        case .missingMedia: String(localized: "The audio file is unavailable.")
        case .decoding: String(localized: "The audio data could not be decoded.")
        case .unsupported: String(localized: "This audio format is not supported by the current playback engine.")
        case .session: String(localized: "The audio system is unavailable. Try playing again.")
        case .cancelled: String(localized: "Playback was cancelled.")
        case .unknown: String(localized: "Audio playback failed. Try playing again.")
        }
    }
}

/// Policy chooses an effect. It never owns or writes transport, queue, or UI state.
nonisolated enum PlaybackRecoveryPolicy {
    enum Decision: Equatable { case ignore, refreshSource, terminal }
    static func decide(_ failure: PlaybackFailure, permitsAudio: Bool, attempted: Bool,
                       canRefresh: Bool, canFallBackToOriginal: Bool = false) -> Decision {
        guard failure.kind != .cancelled else { return .ignore }
        guard permitsAudio, !attempted, canRefresh else { return .terminal }
        switch failure.kind {
        case .network, .unknown: return .refreshSource
        case .decoding, .unsupported: return canFallBackToOriginal ? .refreshSource : .terminal
        default: return .terminal
        }
    }
}
