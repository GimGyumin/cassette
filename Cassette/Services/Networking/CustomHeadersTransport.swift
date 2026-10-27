// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

/// Wraps a base HTTPTransport to inject custom HTTP headers on every outbound request.
///
/// Primary use case: Cloudflare Access tokens (`CF-Access-Client-Id`,
/// `CF-Access-Client-Secret`) and other reverse-proxy authentication headers.
///
/// Security contract:
/// - Header values are never logged — treat them as credentials.
/// - Headers are validated (no \\r / \\n) before storage; this transport trusts the caller.
/// - This transport only covers SwiftSonic requests. AVPlayer and URLSessionDownloadTask
///   require separate header injection at their respective call sites.
///
/// Timeout policy: the default initializer creates a dedicated URLSession with
/// `timeoutIntervalForRequest = 15` and `timeoutIntervalForResource = 20`.
/// The resource timeout (default 7 days in URLSession) is the critical guard
/// against hung Subsonic responses when the server triggers slow external lookups.
struct CustomHeadersTransport: HTTPTransport, Sendable {
    private let base: any HTTPTransport
    private let headers: [String: String]
    private let diagnosticSessionID: String

    /// Normal use case. Creates a dedicated URLSession with snappy cold-start timeouts.
    init(headers: [String: String]) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        // Cap concurrent API calls to the Subsonic host so browse/backfill
        // cannot starve audio streaming on the same server.
        config.httpMaximumConnectionsPerHost = 4
        // Session-level injection ensures headers reach Cloudflare Access on every
        // request path, including any internal URLSession hop before SwiftSonic
        // intercepts the redirect.
        config.httpAdditionalHeaders = headers
        let diagnostics = NetworkTaskDiagnostics()
        self.diagnosticSessionID = diagnostics.sessionID
        self.base = URLSessionTransport(session: URLSession(configuration: config, delegate: diagnostics, delegateQueue: nil))
        self.headers = headers
    }

    /// Testability / advanced use. Inject a pre-configured transport as the base.
    init(base: any HTTPTransport, headers: [String: String]) {
        self.diagnosticSessionID = String(UUID().uuidString.prefix(8))
        self.base = base
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var enriched = request
        let hadAuthorization = enriched.value(forHTTPHeaderField: "Authorization") != nil
        let authCollision = headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
        for (key, value) in headers {
            enriched.setValue(value, forHTTPHeaderField: key)
        }
        let cfId = headers.first(where: { $0.key.caseInsensitiveCompare("CF-Access-Client-Id") == .orderedSame })?.value
        let cfSecret = headers.first(where: { $0.key.caseInsensitiveCompare("CF-Access-Client-Secret") == .orderedSame })?.value
        Logger.httpTransport.debug("CustomHeadersTransport: injected_keys=\(Array(headers.keys).sorted(), privacy: .private) had_auth=\(hadAuthorization, privacy: .public) auth_collision=\(authCollision, privacy: .public)")
        Logger.httpTransport.debug("CustomHeadersTransport CF headers: id=\(cfId.map { $0.isEmpty ? "EMPTY" : "SET" } ?? "ABSENT", privacy: .public) secret=\(cfSecret.map { $0.isEmpty ? "EMPTY" : "SET" } ?? "ABSENT", privacy: .public)")
        let requestID = String(UUID().uuidString.prefix(8))
        let endpoint = NetworkRequestDiagnostics.endpoint(for: request.url)
        let started = ContinuousClock.now
        Logger.httpTransport.info("[HTTP] run=\(RuntimeDiagnostics.sessionID, privacy: .public) session=\(diagnosticSessionID, privacy: .public) request=\(requestID, privacy: .public) endpoint=\(endpoint, privacy: .public) event=start")
        do {
            let result = try await base.data(for: enriched)
            let elapsed = RuntimeDiagnostics.milliseconds(started.duration(to: .now))
            Logger.httpTransport.info("[HTTP] run=\(RuntimeDiagnostics.sessionID, privacy: .public) session=\(diagnosticSessionID, privacy: .public) request=\(requestID, privacy: .public) endpoint=\(endpoint, privacy: .public) event=complete status=\(result.1.statusCode, privacy: .public) duration_ms=\(elapsed, privacy: .public) bytes=\(result.0.count, privacy: .public)")
            return result
        } catch {
            let elapsed = RuntimeDiagnostics.milliseconds(started.duration(to: .now))
            let outcome = NetworkRequestDiagnostics.outcome(for: error)
            let domain = NetworkRequestDiagnostics.domain(for: error)
            Logger.httpTransport.notice("[HTTP] run=\(RuntimeDiagnostics.sessionID, privacy: .public) session=\(diagnosticSessionID, privacy: .public) request=\(requestID, privacy: .public) endpoint=\(endpoint, privacy: .public) event=\(outcome, privacy: .public) domain=\(domain, privacy: .public) code=\((error as NSError).code, privacy: .public) duration_ms=\(elapsed, privacy: .public)")
            throw error
        }
    }
}
