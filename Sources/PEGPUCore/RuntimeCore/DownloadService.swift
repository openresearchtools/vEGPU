import CryptoKit
import Foundation

public final class DownloadService: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: ProgressCenter
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var startedAt = Date()
    private var lastEmitAt = Date()
    private var lastEmitBytes: Int64 = 0

    public init(progress: ProgressCenter = .shared) {
        self.progress = progress
    }

    public func download(_ url: URL, to destination: URL) async throws {
        self.destination = destination
        self.startedAt = Date()
        self.lastEmitAt = Date()
        self.lastEmitBytes = 0
        try? FileManager.default.removeItem(at: destination)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("PEGPU Machine", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination else {
            continuation?.resume(throwing: RuntimeError.message("Download finished without a destination path"))
            continuation = nil
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastEmitAt) >= 0.75 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        let elapsed = max(0.001, now.timeIntervalSince(lastEmitAt))
        let rate = Double(totalBytesWritten - lastEmitBytes) / elapsed
        let avg = Double(totalBytesWritten) / max(0.001, now.timeIntervalSince(startedAt))
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let remaining = total.map { max(0, $0 - totalBytesWritten) }
        progress.report(ProgressEvent(
            stage: "download",
            message: "Downloading Debian runtime image",
            percent: total.map { min(100, Double(totalBytesWritten) / Double($0) * 100) },
            transferredBytes: totalBytesWritten,
            totalBytes: total,
            rateBytesPerSecond: rate > 0 ? rate : avg,
            etaSeconds: remaining.map { avg > 0 ? Double($0) / avg : 0 }
        ))
        lastEmitAt = now
        lastEmitBytes = totalBytesWritten
    }
}

public func sha512Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA512()
    while autoreleasepool(invoking: {
        let data = handle.readData(ofLength: 1024 * 1024)
        if data.isEmpty { return false }
        hasher.update(data: data)
        return true
    }) {}
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
