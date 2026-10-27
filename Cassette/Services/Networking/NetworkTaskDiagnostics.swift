// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// URLs, query strings, headers, error descriptions and response bodies never enter diagnostics.
nonisolated enum NetworkRequestDiagnostics {
    private static let endpoints: Set<String> = [
        "ping", "getalbum", "getalbumlist2", "getartist", "getartists", "getartistinfo2",
        "getartistinfo", "getcoverart", "getlyrics", "getlyricsbysongid", "getlyricsbyartist",
        "getplaylists", "getplaylist", "getgenres", "getstarred2", "getrandomsongs", "getsong",
        "search2", "search3", "getscanstatus", "getopensubsonicextensions", "getsimilarsongs2",
        "gettopsongs", "getmusicdirectory", "getmusicfolders", "getnowplaying", "scrobble",
        "star", "unstar", "setrating", "getplayqueue", "saveplayqueue", "stream", "download",
        "getinternetradiostations", "createplaylist", "updateplaylist", "deleteplaylist"
    ]

    static func endpoint(for url: URL?) -> String {
        let name = url?.deletingPathExtension().lastPathComponent.lowercased() ?? ""
        return endpoints.contains(name) ? name : "other"
    }

    static func outcome(for error: any Error) -> String {
        let nsError = error as NSError
        if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            return "cancelled"
        }
        return "failed"
    }

    static func domain(for error: any Error) -> String {
        let domain = (error as NSError).domain
        return [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain].contains(domain) ? domain : "other"
    }
}

nonisolated struct NetworkTaskMetricsSnapshot: Sendable {
    let taskID: Int
    let durationMS: Int
    let redirects: Int
    let transactions: Int
    let protocolName: String
    let reusedConnection: Bool
    let proxyConnection: Bool
    /// Encoded HTTP bytes, including redirect transactions; not radio/link-layer traffic.
    let bytesSent: Int64
    let bytesReceived: Int64

    init(taskID: Int, metrics: URLSessionTaskMetrics) {
        self.taskID = taskID
        let duration = metrics.taskInterval.duration * 1_000
        durationMS = duration.isFinite && duration >= 0 && duration < Double(Int.max) ? Int(duration) : -1
        redirects = metrics.redirectCount
        transactions = metrics.transactionMetrics.count
        bytesSent = metrics.transactionMetrics.reduce(0) {
            $0 + max(0, $1.countOfRequestHeaderBytesSent) + max(0, $1.countOfRequestBodyBytesSent)
        }
        bytesReceived = metrics.transactionMetrics.reduce(0) {
            $0 + max(0, $1.countOfResponseHeaderBytesReceived) + max(0, $1.countOfResponseBodyBytesReceived)
        }
        let last = metrics.transactionMetrics.last
        let name = last?.networkProtocolName ?? "unknown"
        protocolName = ["http/1.0", "http/1.1", "h2", "h3", "h3-29", "unknown"].contains(name) ? name : "other"
        reusedConnection = last?.isReusedConnection ?? false
        proxyConnection = last?.isProxyConnection ?? false
    }
}

/// Passed to URLSession while SwiftSonic retains ownership of requests and redirect protection.
nonisolated final class NetworkTaskDiagnostics: NSObject, URLSessionTaskDelegate, Sendable {
    let sessionID = String(UUID().uuidString.prefix(8))
    private let observe: (@Sendable (NetworkTaskMetricsSnapshot) -> Void)?

    init(observe: (@Sendable (NetworkTaskMetricsSnapshot) -> Void)? = nil) { self.observe = observe }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let snapshot = NetworkTaskMetricsSnapshot(taskID: task.taskIdentifier, metrics: metrics)
        let endpoint = NetworkRequestDiagnostics.endpoint(for: task.originalRequest?.url)
        Logger.httpTransport.info("[HTTP-METRICS] run=\(RuntimeDiagnostics.sessionID, privacy: .public) session=\(self.sessionID, privacy: .public) task=\(snapshot.taskID, privacy: .public) endpoint=\(endpoint, privacy: .public) duration_ms=\(snapshot.durationMS, privacy: .public) transactions=\(snapshot.transactions, privacy: .public) redirects=\(snapshot.redirects, privacy: .public) protocol=\(snapshot.protocolName, privacy: .public) reused=\(snapshot.reusedConnection, privacy: .public) proxy=\(snapshot.proxyConnection, privacy: .public) sent_bytes=\(snapshot.bytesSent, privacy: .public) received_bytes=\(snapshot.bytesReceived, privacy: .public)")
        observe?(snapshot)
    }
}
