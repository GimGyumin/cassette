// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Unverified decode of a MusicKit developer JWT payload (`iat` / `exp`).
/// Signature is not checked — display / expiry warnings only.
enum MusicKitDeveloperTokenInfo: Sendable {
    /// Days before `exp` when we start urging the user to replace the token.
    static let expiryWarningLeadDays = 14

    /// Apple’s developer portal docs for MusicKit keys + JWT generation.
    static let generatingTokensURL = URL(
        string: "https://developer.apple.com/documentation/applemusicapi/generating_developer_tokens"
    )!

    struct Claims: Sendable, Equatable {
        var issuedAt: Date?
        var expiresAt: Date?
        var teamID: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }

        /// True when expiry is within the warning window (or already past).
        var needsReplacementSoon: Bool {
            guard let expiresAt else { return false }
            let leadDays = MusicKitDeveloperTokenInfo.expiryWarningLeadDays
            let lead = Date().addingTimeInterval(TimeInterval(leadDays * 24 * 3600))
            return expiresAt <= lead
        }
    }

    enum ValidationError: LocalizedError {
        case empty
        case notJWT
        case expired
        case missingExpiry

        var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "Paste a MusicKit developer JWT.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            case .notJWT:
                return String(localized: "That doesn’t look like a MusicKit JWT (three Base64 parts separated by dots).", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            case .expired:
                return String(localized: "This JWT is already expired. Generate a new developer token.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            case .missingExpiry:
                return String(localized: "JWT is missing an exp claim. Generate a token with iat and exp.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            }
        }
    }

    /// Strips whitespace and an optional `Bearer ` prefix.
    static func sanitize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    static func parse(_ jwt: String) -> Claims? {
        let trimmed = sanitize(jwt)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let payloadData = base64URLDecode(String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return Claims(
            issuedAt: date(from: json["iat"]),
            expiresAt: date(from: json["exp"]),
            teamID: json["iss"] as? String
        )
    }

    /// Validates shape + expiry before saving into Settings.
    static func validateForSave(_ raw: String) -> Result<String, ValidationError> {
        let trimmed = sanitize(raw)
        if trimmed.isEmpty { return .success("") }
        guard let claims = parse(trimmed) else { return .failure(.notJWT) }
        guard claims.expiresAt != nil else { return .failure(.missingExpiry) }
        if claims.isExpired { return .failure(.expired) }
        return .success(trimmed)
    }

    private static func date(from value: Any?) -> Date? {
        if let n = value as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        if let i = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(i))
        }
        if let d = value as? Double {
            return Date(timeIntervalSince1970: d)
        }
        return nil
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = 4 - s.count % 4
        if pad < 4 { s.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: s)
    }
}
