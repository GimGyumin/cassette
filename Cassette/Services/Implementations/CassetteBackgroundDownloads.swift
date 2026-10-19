// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import ImageIO
import OSLog

/// Shared background `URLSession` for offline track downloads so transfers continue
/// while the app is suspended (not only while it stays in the foreground).
nonisolated final class CassetteBackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "app.cassette.downloads"
    static let shared = CassetteBackgroundDownloads()
    static let artworkSessionIdentifier = "app.cassette.artwork-downloads"
    static let artwork = CassetteBackgroundDownloads(identifier: artworkSessionIdentifier)
    private let identifier: String
    private let journal: BackgroundDownloadJournal
    private let sessionConfiguration: URLSessionConfiguration?

    private struct Pending {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
        let task: URLSessionDownloadTask
        var response: URLResponse?
        var fileURL: URL?
        var onProgress: (@Sendable (Int64, Int64?) -> Void)?
        var persistentArtworkURL: URL?
        var recoveryID: UUID?
        var progressThrottle = DownloadProgressThrottle()
    }

    private let lock = NSLock()
    private var pendingByTaskId: [Int: Pending] = [:]
    private var taskIdByClientKey: [String: Int] = [:]
    private var artworkTasks: [String: URLSessionDownloadTask] = [:]
    private var artworkDestinations: [Int: URL] = [:]
    private var artworkRetries: [String: Int] = [:]
    private var backgroundEventsCompletion: (() -> Void)?
    private let sessionLock = NSLock()
    private var cachedSession: URLSession?
    private var recoveryHandler: (@Sendable () async -> Void)?

    func setRecoveryHandler(_ handler: @escaping @Sendable () async -> Void) {
        lock.withLock { recoveryHandler = handler }
        _ = session
    }

    private var session: URLSession {
        sessionLock.withLock {
            if let cachedSession { return cachedSession }
            let config = sessionConfiguration ?? URLSessionConfiguration.background(withIdentifier: identifier)
            config.isDiscretionary = false
            if sessionConfiguration == nil { config.sessionSendsLaunchEvents = true }
            config.allowsCellularAccess = true
            if identifier == Self.artworkSessionIdentifier { ArtworkNetworkPolicy.configure(config) }
            config.waitsForConnectivity = true
            // Bulk images must leave the server's uplink available for streaming audio.
            config.httpMaximumConnectionsPerHost = identifier == Self.artworkSessionIdentifier ? 1 : 4
            config.timeoutIntervalForRequest = 60
            // Large FLACs over slow links need a long resource budget in the background.
            config.timeoutIntervalForResource = identifier == Self.artworkSessionIdentifier ? 120 : 60 * 60 * 6
            let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            cachedSession = created
            return created
        }
    }

    init(identifier: String = CassetteBackgroundDownloads.sessionIdentifier,
         journal: BackgroundDownloadJournal = .shared,
         configuration: URLSessionConfiguration? = nil) {
        self.identifier = identifier
        self.journal = journal
        self.sessionConfiguration = configuration
        super.init()
    }

    /// Ensures the session exists so the system can deliver background events after relaunch.
    func prepareForBackgroundEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundEventsCompletion = completionHandler
        lock.unlock()
        _ = session
    }

    /// Recover daemon-owned work before admitting a library batch after relaunch.
    func restoreArtworkTasks() async {
        let tasks = await session.allTasks
        lock.withLock {
            for case let task as URLSessionDownloadTask in tasks {
                guard let descriptor = task.taskDescription, descriptor.hasPrefix("artwork:"),
                      task.state == .running || task.state == .suspended else { continue }
                artworkTasks[descriptor] = task
            }
        }
    }

    /// Submit the whole inventory, without waiting for each previous transfer to finish.
    /// URLSession, rather than an in-process Swift task, advances this queue while suspended.
    /// Callers fence account changes before this synchronous admission step.
    func enqueueArtwork(request: URLRequest, destination: URL) {
        let session = self.session
        lock.withLock {
            let descriptor = "artwork:" + destination.lastPathComponent
            guard artworkTasks[descriptor] == nil,
                  !Self.isValidArtwork(at: destination) else { return }
            var request = request
            ArtworkNetworkPolicy.apply(to: &request)
            let task = session.downloadTask(with: request)
            task.taskDescription = descriptor
            task.priority = URLSessionTask.lowPriority
            artworkTasks[descriptor] = task
            artworkDestinations[task.taskIdentifier] = destination
            task.resume()
        }
    }

    /// Downloads `request` to a temporary file URL. Cancelling the surrounding `Task`
    /// (or calling `cancel(clientKey:)`) cancels the underlying session task.
    func download(
        request: URLRequest,
        clientKey: String,
        persistentArtworkURL: URL? = nil,
        recoveryID: UUID? = nil,
        onProgress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
                var request = request
                if self.identifier == Self.artworkSessionIdentifier { ArtworkNetworkPolicy.apply(to: &request) }
                let session = self.session
                self.lock.lock()
                // A queued original may have finished before its progress observer arrived.
                // The delegate uses the same lock, closing the check/attach race.
                if let destination = persistentArtworkURL,
                   Self.isValidArtwork(at: destination) {
                    self.lock.unlock()
                    continuation.resume(returning: (destination, URLResponse(url: destination,
                        mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
                    return
                }
                let descriptor = persistentArtworkURL.map { "artwork:" + $0.lastPathComponent }
                let candidate = descriptor.flatMap { self.artworkTasks[$0] }
                // Pending has one owner. A replacement client must not cancel the very
                // same task it just adopted; only observer-free batch jobs are adopted.
                let existing = candidate.flatMap { self.pendingByTaskId[$0.taskIdentifier] == nil ? $0 : nil }
                let task = existing ?? session.downloadTask(with: request)
                if let persistentArtworkURL {
                    task.taskDescription = "artwork:" + persistentArtworkURL.lastPathComponent
                    self.artworkTasks["artwork:" + persistentArtworkURL.lastPathComponent] = task
                    self.artworkDestinations[task.taskIdentifier] = persistentArtworkURL
                    task.priority = URLSessionTask.lowPriority
                } else if let recoveryID {
                    task.taskDescription = "audio:" + recoveryID.uuidString
                }
                let old = self.taskIdByClientKey[clientKey].flatMap { self.pendingByTaskId.removeValue(forKey: $0) }
                old?.task.taskDescription = nil
                self.pendingByTaskId[task.taskIdentifier] = Pending(
                    continuation: continuation,
                    task: task,
                    onProgress: onProgress,
                    persistentArtworkURL: persistentArtworkURL,
                    recoveryID: recoveryID
                )
                self.taskIdByClientKey[clientKey] = task.taskIdentifier
                self.lock.unlock()
                old?.task.cancel()
                if let id = old?.recoveryID { journal.remove(id) }
                if old?.persistentArtworkURL == nil, let file = old?.fileURL {
                    try? FileManager.default.removeItem(at: file)
                }
                old?.continuation.resume(throwing: CancellationError())
                if Task.isCancelled {
                    self.cancel(clientKey: clientKey, recoveryID: recoveryID)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel(clientKey: clientKey, recoveryID: recoveryID)
        }
    }

    func cancel(clientKey: String, recoveryID: UUID? = nil) {
        lock.lock()
        if let recoveryID {
            guard let taskID = taskIdByClientKey[clientKey],
                  pendingByTaskId[taskID]?.recoveryID == recoveryID else { lock.unlock(); return }
        }
        let taskId = taskIdByClientKey.removeValue(forKey: clientKey)
        let pending = taskId.flatMap { pendingByTaskId.removeValue(forKey: $0) }
        if let descriptor = pending?.task.taskDescription {
            artworkTasks.removeValue(forKey: descriptor)
            artworkRetries.removeValue(forKey: descriptor)
        }
        if let taskId { artworkDestinations.removeValue(forKey: taskId) }
        pending?.task.taskDescription = nil
        lock.unlock()

        pending?.task.cancel()
        if let id = pending?.recoveryID { journal.remove(id) }
        if pending?.persistentArtworkURL == nil, let file = pending?.fileURL { try? FileManager.default.removeItem(at: file) }
        pending?.continuation.resume(throwing: CancellationError())
    }

    /// Drain both current and system-restored artwork transfers before account files are removed.
    func cancelAll() async {
        let tasks = await session.allTasks
        let abandoned = lock.withLock { () -> [Pending] in
            // A retry may have been admitted after allTasks returned. Drain the registry too.
            for task in tasks + Array(artworkTasks.values) { task.taskDescription = nil; task.cancel() }
            let values = Array(pendingByTaskId.values)
            pendingByTaskId.removeAll()
            taskIdByClientKey.removeAll()
            artworkTasks.removeAll()
            artworkDestinations.removeAll()
            artworkRetries.removeAll()
            return values
        }
        for pending in abandoned { pending.continuation.resume(throwing: CancellationError()) }
        if identifier != Self.artworkSessionIdentifier { journal.removeAll() }
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
                ?? artworkDestinations[downloadTask.taskIdentifier]
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("app.cassette/coverarts", isDirectory: true).appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Atomic replacement keeps an interrupted transfer from looking complete on resume.
                let data = try Data(contentsOf: location, options: .mappedIfSafe)
                try ArtworkContentStore.write(data, to: destination)
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
        if let descriptor = downloadTask.taskDescription, descriptor.hasPrefix("audio:"),
           let id = UUID(uuidString: String(descriptor.dropFirst(6))) {
            do {
                guard downloadTask.state != .canceling else { throw CancellationError() }
                let response = downloadTask.response ?? URLResponse()
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw HTTPTransferFailure(response: response, stage: "background audio response")
                }
                try AudioResponseValidator.validate(fileAt: location, response: response,
                    songId: "background-download", logger: .download)
                let file = try journal.stage(id: id, file: location, response: response)
                lock.withLock {
                    if var pending = pendingByTaskId[downloadTask.taskIdentifier] {
                        pending.fileURL = file
                        pending.response = response
                        pendingByTaskId[downloadTask.taskIdentifier] = pending
                    }
                }
            } catch {
                journal.remove(id)
                let pending = lock.withLock { () -> Pending? in
                    removeClientKey(forTaskId: downloadTask.taskIdentifier)
                    return pendingByTaskId.removeValue(forKey: downloadTask.taskIdentifier)
                }
                pending?.continuation.resume(throwing: error)
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
        var pending = pendingByTaskId[downloadTask.taskIdentifier]
        let emit = pending?.progressThrottle.shouldEmit(now: ProcessInfo.processInfo.systemUptime,
            received: totalBytesWritten, expected: totalBytesExpectedToWrite) == true
        if let pending { pendingByTaskId[downloadTask.taskIdentifier] = pending }
        let progress = emit ? pending?.onProgress : nil
        lock.unlock()
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progress?(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, task.taskDescription?.hasPrefix("audio:") == true,
           PlaybackFailure.classify(error).kind != .cancelled {
            let failure = PlaybackFailure.classify(error)
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            let endpoint = task.originalRequest?.url?.lastPathComponent ?? "unknown"
            Logger.download.error("[AUDIO-DOWNLOAD] phase=transport endpoint=\(endpoint, privacy: .public) status=\(status) domain=\(failure.domain, privacy: .public) code=\(failure.code) received=\(task.countOfBytesReceived)")
        }
        lock.lock()
        let pending = pendingByTaskId.removeValue(forKey: task.taskIdentifier)
        if let descriptor = task.taskDescription, descriptor.hasPrefix("artwork:"),
           let request = task.originalRequest,
           Self.shouldRetryArtwork(error: error, response: task.response),
           artworkRetries[descriptor, default: 0] < 2,
           artworkTasks[descriptor]?.taskIdentifier == task.taskIdentifier {
            artworkRetries[descriptor, default: 0] += 1
            let retry = session.downloadTask(with: request)
            retry.taskDescription = descriptor
            retry.priority = URLSessionTask.lowPriority
            artworkTasks[descriptor] = retry
            let destination = artworkDestinations.removeValue(forKey: task.taskIdentifier)
            artworkDestinations[retry.taskIdentifier] = destination
            if let pending {
                pendingByTaskId[retry.taskIdentifier] = Pending(continuation: pending.continuation, task: retry,
                    onProgress: pending.onProgress, persistentArtworkURL: pending.persistentArtworkURL,
                    recoveryID: pending.recoveryID)
                for key in Array(taskIdByClientKey.keys) where taskIdByClientKey[key] == task.taskIdentifier {
                    taskIdByClientKey[key] = retry.taskIdentifier
                }
            }
            lock.unlock()
            retry.resume()
            return
        }
        if let descriptor = task.taskDescription,
           artworkTasks[descriptor]?.taskIdentifier == task.taskIdentifier {
            artworkTasks.removeValue(forKey: descriptor)
            artworkRetries.removeValue(forKey: descriptor)
        }
        artworkDestinations.removeValue(forKey: task.taskIdentifier)
        removeClientKey(forTaskId: task.taskIdentifier)
        lock.unlock()
        guard let pending else {
            if error != nil, let descriptor = task.taskDescription, descriptor.hasPrefix("audio:"),
               let id = UUID(uuidString: String(descriptor.dropFirst(6))) {
                journal.remove(id)
            }
            return
        }

        if let error {
            if let id = pending.recoveryID { journal.remove(id) }
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

    static func shouldRetryArtwork(error: Error?, response: URLResponse?) -> Bool {
        if let error {
            let code = (error as? URLError)?.code
            return code == .timedOut || code == .networkConnectionLost || code == .cannotConnectToHost
                || code == .cannotFindHost || code == .notConnectedToInternet
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return status == 429 || (500...599).contains(status)
    }

    static func isValidArtwork(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
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
        let recovery = recoveryHandler
        lock.unlock()
        Task {
            // Register restored payloads before releasing the OS background execution window.
            await recovery?()
            await MainActor.run { completion?() }
        }
    }

    private func removeClientKey(forTaskId taskId: Int) {
        if let key = taskIdByClientKey.first(where: { $0.value == taskId })?.key {
            taskIdByClientKey.removeValue(forKey: key)
        }
    }
}
