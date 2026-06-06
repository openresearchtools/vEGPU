import Foundation
import Network

public struct NativeBridgeInfo: Codable, Equatable, Sendable {
    public var url: String
    public var token: String
}

public final class NativeBridgeService: @unchecked Sendable {
    private let runtime: LlmsRuntimeService
    private let queue = DispatchQueue(label: "com.pegpu.app.native-bridge")
    private var listener: NWListener?
    private var token: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    public init(runtime: LlmsRuntimeService) {
        self.runtime = runtime
    }

    public func start(port: UInt16 = 39_292) throws -> NativeBridgeInfo {
        if let listener {
            return NativeBridgeInfo(url: bridgeURL(listener: listener, fallbackPort: port), token: token)
        }
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        return NativeBridgeInfo(url: bridgeURL(listener: listener, fallbackPort: port), token: token)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public func environment() throws -> [String: String] {
        let info = try start()
        return [
            "PEGPU_NATIVE_BRIDGE_URL": info.url,
            "PEGPU_NATIVE_BRIDGE_TOKEN": info.token
        ]
    }

    private func bridgeURL(listener: NWListener, fallbackPort: UInt16) -> String {
        let rawPort = listener.port?.rawValue ?? 0
        let resolvedPort = rawPort == 0 ? fallbackPort : rawPort
        return "http://127.0.0.1:\(resolvedPort)"
    }

    private func handle(connection: NWConnection) {
        let handler = NativeBridgeConnection(connection: connection, token: token, runtime: runtime)
        handler.start(queue: queue)
    }
}

private final class NativeBridgeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let runtime: LlmsRuntimeService
    private var buffer = Data()

    init(connection: NWConnection, token: String, runtime: LlmsRuntimeService) {
        self.connection = connection
        self.token = token
        self.runtime = runtime
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if let request = HTTPBridgeRequest(data: self.buffer) {
                self.handle(request)
                return
            }
            if isComplete || error != nil {
                self.send(status: 400, body: "bad request\n")
                return
            }
            self.receive()
        }
    }

    private func handle(_ request: HTTPBridgeRequest) {
        guard request.path == "/api/native/llms-runtime" else {
            send(status: 404, body: "not found\n")
            return
        }
        guard request.method == "POST" else {
            send(status: 405, body: "method not allowed\n")
            return
        }
        let supplied = request.headers["x-pegpu-bridge-token"] ?? request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
        guard supplied == token else {
            send(status: 401, body: "unauthorized\n")
            return
        }
        Task {
            do {
                let payload = try JSON.decoder.decode(BridgeCommandPayload.self, from: request.body)
                let output = try await runtime.command(args: payload.args)
                send(status: 200, body: output, contentType: "application/json; charset=utf-8")
            } catch {
                send(status: 500, body: "\(error)\n")
            }
        }
    }

    private func send(status: Int, body: String, contentType: String = "text/plain; charset=utf-8") {
        let reason = HTTPBridgeResponse.reason(for: status)
        let data = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}

private struct BridgeCommandPayload: Codable {
    var args: [String]
}

private struct HTTPBridgeRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(data: Data) {
        guard let separator = data.httpHeaderSeparatorRange,
              let headerText = String(data: data.subdata(in: 0..<separator.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerText.split(whereSeparator: \.isNewline).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ").map(String.init)
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        let bodyStart = separator.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + contentLength else { return nil }
        self.method = requestParts[0]
        self.path = requestParts[1]
        self.headers = headers
        self.body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
    }
}

private extension Data {
    var httpHeaderSeparatorRange: Range<Int>? {
        if let range = firstRange(of: Data([13, 10, 13, 10])) {
            return range.lowerBound..<range.upperBound
        }
        if let range = firstRange(of: Data([10, 10])) {
            return range.lowerBound..<range.upperBound
        }
        return nil
    }
}

private enum HTTPBridgeResponse {
    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Internal Server Error"
        }
    }
}
