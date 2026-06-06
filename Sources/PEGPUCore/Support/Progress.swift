import Foundation

public enum ProgressLevel: String, Codable, Sendable {
    case info
    case success
    case error
}

public struct ProgressEvent: Codable, Sendable, Identifiable {
    public var id: String { "\(timestamp.timeIntervalSince1970)-\(stage)-\(message)" }
    public let stage: String
    public let message: String
    public let detail: String?
    public let percent: Double?
    public let transferredBytes: Int64?
    public let totalBytes: Int64?
    public let rateBytesPerSecond: Double?
    public let etaSeconds: Double?
    public let level: ProgressLevel
    public let timestamp: Date

    public init(
        stage: String,
        message: String,
        detail: String? = nil,
        percent: Double? = nil,
        transferredBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        rateBytesPerSecond: Double? = nil,
        etaSeconds: Double? = nil,
        level: ProgressLevel = .info,
        timestamp: Date = Date()
    ) {
        self.stage = stage
        self.message = message
        self.detail = detail
        self.percent = percent
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.rateBytesPerSecond = rateBytesPerSecond
        self.etaSeconds = etaSeconds
        self.level = level
        self.timestamp = timestamp
    }
}

public final class ProgressCenter: @unchecked Sendable {
    public static let shared = ProgressCenter()

    public init() {}

    private let lock = NSLock()
    private var listeners: [UUID: (ProgressEvent) -> Void] = [:]

    public func report(_ event: ProgressEvent) {
        lock.lock()
        let callbacks = Array(listeners.values)
        lock.unlock()
        callbacks.forEach { $0(event) }
    }

    @discardableResult
    public func observe(_ callback: @escaping (ProgressEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners[id] = callback
        lock.unlock()
        return id
    }

    public func remove(_ id: UUID) {
        lock.lock()
        listeners.removeValue(forKey: id)
        lock.unlock()
    }
}
