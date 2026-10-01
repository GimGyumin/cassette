// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Shared background `URLSession` for offline track downloads so transfers continue
/// while the app is suspended (not only while it stays in the foreground).
final class CassetteBackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "app.cassette.downloads"
    static let shared = CassetteBackgroundDownloads()

    private struct Pending {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
        let task: URLSessionDownloadTask
        var response: URLResponse?
        var fileURL: URL?
        var onProgress: (@Sendable (Int64, Int64?) -> Void)?
    }

    private let lock = NSLock()
    private var pendingByTaskId: [Int: Pending] = [:]
    private var taskIdByClientKey: [String: Int] = [:]
    private var backgroundEventsCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        // Large FLACs over slow links need a long resource budget in the background.
        config.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
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
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                let task = self.session.downloadTask(with: request)
                self.lock.lock()
                let old = self.taskIdByClientKey[clientKey].flatMap { self.pendingByTaskId.removeValue(forKey: $0) }
                self.pendingByTaskId[task.taskIdentifier] = Pending(
                    continuation: continuation,
                    task: task,
                    onProgress: onProgress
                )
                self.taskIdByClientKey[clientKey] = task.taskIdentifier
                self.lock.unlock()
                old?.task.cancel()
                if let file = old?.fileURL { try? FileManager.default.removeItem(at: file) }
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
        lock.unlock()

        pending?.task.cancel()
        if let file = pending?.fileURL { try? FileManager.default.removeItem(at: file) }
        pending?.continuation.resume(throwing: CancellationError())
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
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
            if let fileURL = pending.fileURL {
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
