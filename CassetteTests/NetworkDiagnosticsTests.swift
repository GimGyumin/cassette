// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Cassette

@Suite("Network diagnostics privacy and transport integration")
struct NetworkDiagnosticsTests {
    @Test func endpointLabelsNeverIncludeCredentialsOrMediaPaths() throws {
        let authenticated = try #require(URL(string: "https://user:secret@example.invalid/private/getAlbum.view?u=user&t=secret&id=private-album"))
        #expect(NetworkRequestDiagnostics.endpoint(for: authenticated) == "getalbum")
        #expect(NetworkRequestDiagnostics.endpoint(for: URL(string: "https://example.invalid/access-token-secret")) == "other")
        #expect(NetworkRequestDiagnostics.endpoint(for: URL(string: "https://example.invalid/secret?endpoint=getAlbum")) == "other")
        #expect(NetworkRequestDiagnostics.endpoint(for: nil) == "other")
    }

    @Test func cancellationIsDistinctFromFailureWithoutUsingErrorDescriptions() {
        #expect(NetworkRequestDiagnostics.outcome(for: CancellationError()) == "cancelled")
        #expect(NetworkRequestDiagnostics.outcome(for: URLError(.cancelled)) == "cancelled")
        #expect(NetworkRequestDiagnostics.outcome(for: URLError(.networkConnectionLost)) == "failed")
        let unrelated = NSError(domain: "secret-token", code: NSURLErrorCancelled,
                                userInfo: [NSLocalizedDescriptionKey: "https://user:secret@example.invalid"])
        #expect(NetworkRequestDiagnostics.outcome(for: unrelated) == "failed")
        #expect(NetworkRequestDiagnostics.domain(for: unrelated) == "other")
        #expect(NetworkRequestDiagnostics.domain(for: URLError(.timedOut)) == NSURLErrorDomain)
    }

}
