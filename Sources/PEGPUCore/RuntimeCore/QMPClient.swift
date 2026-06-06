import Foundation
import Darwin

public final class QMPClient: @unchecked Sendable {
    private let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public func execute(_ name: String, arguments: [String: Any]? = nil) async throws -> Any? {
        try await executePayload(name, arguments: arguments).value
    }

    public func executeVoid(_ name: String, arguments: [String: Any]? = nil) async throws {
        _ = try await executePayload(name, arguments: arguments)
    }

    public func queryMice() async throws -> [QMPMouseInfo] {
        guard let rows = try await executePayload("query-mice").value as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let absolute = row["absolute"] as? Bool,
                  let index = row["index"] as? Int else {
                return nil
            }
            return QMPMouseInfo(index: index, absolute: absolute)
        }
    }

    private func executePayload(_ name: String, arguments: [String: Any]? = nil) async throws -> QMPPayload {
        let socket = try await connectUnixSocket(path: socketURL.path)
        defer { close(socket) }
        _ = try readQMPMessage(socket)
        try writeQMP(socket, ["execute": "qmp_capabilities"])
        _ = try readQMPMessage(socket)
        var payload: [String: Any] = ["execute": name]
        if let arguments {
            payload["arguments"] = arguments
        }
        try writeQMP(socket, payload)
        let response = try readQMPMessage(socket)
        if let error = response["error"] {
            throw RuntimeError.message("QMP \(name) failed: \(error)")
        }
        return QMPPayload(value: response["return"])
    }

    public static func frame(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload) + Data("\r\n".utf8)
    }

    private func connectUnixSocket(path: String) async throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPath else {
            close(fd)
            throw RuntimeError.message("QMP socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: CChar.self, repeating: 0)
            path.withCString { src in
                raw.baseAddress!.copyMemory(from: src, byteCount: path.utf8.count)
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return fd
    }

    private func writeQMP(_ fd: Int32, _ payload: [String: Any]) throws {
        let data = try Self.frame(payload)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 { throw POSIXError(.EIO) }
                sent += n
            }
        }
    }

    private func readQMPMessage(_ fd: Int32) throws -> [String: Any] {
        var buffer = Data()
        var byte = UInt8(0)
        repeat {
            let count = Darwin.read(fd, &byte, 1)
            if count <= 0 { throw POSIXError(.EIO) }
            if byte == 0x0a { break }
            if byte != 0x0d { buffer.append(byte) }
        } while true
        let object = try JSONSerialization.jsonObject(with: buffer)
        guard let dict = object as? [String: Any] else {
            throw RuntimeError.message("QMP returned a non-object response")
        }
        return dict
    }
}

private struct QMPPayload: @unchecked Sendable {
    let value: Any?
}

public struct QMPMouseInfo: Sendable {
    public let index: Int
    public let absolute: Bool
}
