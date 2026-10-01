// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CryptoKit
import Foundation
import SwiftSonic

/// Quick vs full library scan. OpenSubsonic `startScan` has no mode; Navidrome
/// accepts `fullScan=true` as an extension — ignored by servers that don't support it.
enum LibraryScanMode: Sendable {
    case quick
    case full
}

enum LibraryScanError: LocalizedError {
    case invalidServerURL
    case badResponse
    case api(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return String(localized: "Invalid server URL.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .badResponse:
            return String(localized: "The server returned an unexpected response.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .api(let message):
            return message
        }
    }
}

/// Starts a library scan (optional Navidrome `fullScan`) and polls status via SwiftSonic.
enum LibraryScanService {
    static func startScan(
        mode: LibraryScanMode,
        baseURL: String,
        username: String,
        serverService: any ServerServiceProtocol
    ) async throws -> ScanStatus {
        switch mode {
        case .quick:
            let client = try await serverService.makeSwiftSonicClient()
            return try await client.startScan()
        case .full:
            do {
                return try await startFullScan(
                    baseURL: baseURL,
                    username: username,
                    serverService: serverService
                )
            } catch {
                let client = try await serverService.makeSwiftSonicClient()
                return try await client.startScan()
            }
        }
    }

    static func status(serverService: any ServerServiceProtocol) async throws -> ScanStatus {
        let client = try await serverService.makeSwiftSonicClient()
        return try await client.getScanStatus()
    }

    // MARK: - Full scan (Navidrome extension)

    private static func startFullScan(
        baseURL: String,
        username: String,
        serverService: any ServerServiceProtocol
    ) async throws -> ScanStatus {
        let creds = try await serverService.activeCredentials()
        guard var components = URLComponents(string: baseURL) else {
            throw LibraryScanError.invalidServerURL
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/rest/startScan.view"

        let salt = randomSalt()
        let token = md5Hex(creds.password + salt)
        components.queryItems = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Cassette"),
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "fullScan", value: "true"),
        ]
        guard let url = components.url else { throw LibraryScanError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in creds.customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LibraryScanError.badResponse
        }
        return try decodeScanStatus(from: data)
    }

    private static func decodeScanStatus(from data: Data) throws -> ScanStatus {
        struct Envelope: Decodable {
            let subsonicResponse: Inner
            enum CodingKeys: String, CodingKey {
                case subsonicResponse = "subsonic-response"
            }
            struct Inner: Decodable {
                let status: String
                let error: APIError?
                let scanStatus: ScanStatus?
                struct APIError: Decodable {
                    let message: String?
                }
            }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if envelope.subsonicResponse.status != "ok" {
            throw LibraryScanError.api(
                message: envelope.subsonicResponse.error?.message
                    ?? String(localized: "The server returned an API-level error.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            )
        }
        guard let status = envelope.subsonicResponse.scanStatus else {
            throw LibraryScanError.badResponse
        }
        return status
    }

    private static func randomSalt(length: Int = 12) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
