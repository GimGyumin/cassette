// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import ImageIO

/// Shared background `URLSession` for offline track downloads so transfers continue
/// while the app is suspended (not only while it stays in the foreground).
nonisolated final class CassetteBackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "app.cassette.downloads"
    static let shared = CassetteBackgroundDownloads()
    static let artworkSessionIdentifier = "app.cassette.artwork-downloads"
    static let artwork = CassetteBackgroundDownloads(identifier: artworkSessionIdentifier)
    private let identifier: String

    private struct Pending {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
        let task: URLSessionDownloadTask
        var response: URLResponse?
        var fileURL: URL?
        var onProgress: (@Sendable (Int64, Int64?) -> Void)?
        var persistentArtworkURL: URL?
    }

    private let lock = NSLock()
    private var pendingByTaskId: [Int: Pending] = [:]
    private var taskIdByClientKey: [String: Int] = [:]
    private var backgroundEventsCompletion: (() -> Void)?
    private let sessionLock = NSLock()
    private var cachedSession: URLSession?

    private var session: URLSession {
        sessionLock.withLock {
            if let cachedSession { return cachedSession }
            let config = URLSessionConfiguration.background(withIdentifier: identifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.allowsCellularAccess = true
            config.waitsForConnectivity = true
            config.httpMaximumConnectionsPerHost = 4
            config.timeoutIntervalForRequest = 60
            // Large FLACs over slow links need a long resource budget in the background.
            config.timeoutIntervalForResource = 60 * 60 * 6
            let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            cachedSession = created
            return created
        }
    }

    private init(identifier: String = CassetteBackgroundDownloads.sessionIdentifier) {
        self.identifier = identifier
        super.init()
    }

    /// Ensures the session exists so the system can deliver background events after relaunch.
    func prepareForBackgroundEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundEventsCompletion = completionHandler
        lock.unlock()
        _ = session
    }

    /// Downloads `request` to a temporary file URL. Cancelling the surrounding `Task`
    /// (or calling `cancel(clientKey:)`) cancels the underlying session task.
    func download(
        request: URLRequest,
        clientKey: String,
        persistentArtworkURL: URL? = nil,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                let task = self.session.downloadTask(with: request)
                if let persistentArtworkURL {
                    task.taskDescription = "artwork:" + persistentArtworkURL.lastPathComponent
                }
                self.lock.lock()
                let old = self.taskIdByClientKey[clientKey].flatMap { self.pendingByTaskId.removeValue(forKey: $0) }
                old?.task.taskDescription = nil
                self.pendingByTaskId[task.taskIdentifier] = Pending(
                    continuation: continuation,
                    task: task,
                    onProgress: onProgress,
                    persistentArtworkURL: persistentArtworkURL
                )
                self.taskIdByClientKey[clientKey] = task.taskIdentifier
                self.lock.unlock()
                old?.task.cancel()
                if old?.persistentArtworkURL == nil, let file = old?.fileURL {
                    try? FileManager.default.removeItem(at: file)
                }
                old?.continuation.resume(throwing: CancellationError())
                if Task.isCancelled {
                    self.cancel(clientKey: clientKey)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel(clientKey: clientKey)
        }
    }

    func cancel(clientKey: String) {
        lock.lock()
        let taskId = taskIdByClientKey.removeValue(forKey: clientKey)
        let pending = taskId.flatMap { pendingByTaskId.removeValue(forKey: $0) }
        pending?.task.taskDescription = nil
        lock.unlock()

        pending?.task.cancel()
        if pending?.persistentArtworkURL == nil, let file = pending?.fileURL { try? FileManager.default.removeItem(at: file) }
        pending?.continuation.resume(throwing: CancellationError())
    }

    /// Drain both current and system-restored artwork transfers before account files are removed.
    func cancelAll() async {
        let tasks = await session.allTasks
        let abandoned = lock.withLock { () -> [Pending] in
            for task in tasks { task.taskDescription = nil; task.cancel() }
            let values = Array(pendingByTaskId.values)
            pendingByTaskId.removeAll()
            taskIdByClientKey.removeAll()
            return values
        }
        for pending in abandoned { pending.continuation.resume(throwing: CancellationError()) }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // A task description survives process termination; save completed originals even
        // when the Swift continuation that enqueued them no longer exists.
        if identifier == Self.artworkSessionIdentifier {
            lock.lock()
            defer { lock.unlock() }
            guard downloadTask.state != .canceling,
                  let descriptor = downloadTask.taskDescription,
                  descriptor.hasPrefix("artwork:"),
                  let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  Self.isValidArtwork(at: location) else { return }
            let name = String(descriptor.dropFirst("artwork:".count))
            guard !name.contains("/"), name.hasSuffix("@original-v1") else { return }
            let destination = pendingByTaskId[downloadTask.taskIdentifier]?.persistentArtworkURL
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("app.cassette/coverarts", isDirectory: true).appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Atomic replacement keeps an interrupted transfer from looking complete on resume.
                let data = try Data(contentsOf: location, options: .mappedIfSafe)
                try data.write(to: destination, options: .atomic)
                if var pending = pendingByTaskId[downloadTask.taskIdentifier] {
                    pending.fileURL = destination
                    pending.response = response
                    pendingByTaskId[downloadTask.taskIdentifier] = pending
                }
            } catch {
                // didCompleteWithError resumes the waiting caller with cannotOpenFile.
            }
            return
        }
        // The system deletes `location` when this method returns — copy immediately.
        let tempDir = FileManager.default.temporaryDirectory
        let dest = tempDir.appendingPathComponent("cassette-dl-\(UUID().uuidString)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: location, to: dest)
        } catch {
            lock.lock()
            let pending = pendingByTaskId.removeValue(forKey: downloadTask.taskIdentifier)
            removeClientKey(forTaskId: downloadTask.taskIdentifier)
            lock.unlock()
            pending?.continuation.resume(throwing: error)
            return
        }

        lock.lock()
        if var pending = pendingByTaskId[downloadTask.taskIdentifier] {
            pending.fileURL = dest
            pending.response = downloadTask.response
            pendingByTaskId[downloadTask.taskIdentifier] = pending
        } else {
            try? FileManager.default.removeItem(at: dest)
        }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let progress = pendingByTaskId[downloadTask.taskIdentifier]?.onProgress
        lock.unlock()
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progress?(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = pendingByTaskId.removeValue(forKey: task.taskIdentifier)
        removeClientKey(forTaskId: task.taskIdentifier)
        lock.unlock()
        guard let pending else { return }

        if let error {
            if pending.persistentArtworkURL == nil, let fileURL = pending.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            pending.continuation.resume(throwing: error)
            return
        }

        guard let fileURL = pending.fileURL else {
            pending.continuation.resume(
                throwing: URLError(.cannotOpenFile)
            )
            return
        }
        let response = pending.response ?? task.response ?? URLResponse()
        pending.continuation.resume(returning: (fileURL, response))
    }

    static func isValidArtwork(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && CGImageSourceGetStatus(source) == .statusComplete
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        lock.unlock()
        DispatchQueue.main.async {
            completion?()
        }
    }

    private func removeClientKey(forTaskId taskId: Int) {
        if let key = taskIdByClientKey.first(where: { $0.value == taskId })?.key {
            taskIdByClientKey.removeValue(forKey: key)
        }
    }
}
