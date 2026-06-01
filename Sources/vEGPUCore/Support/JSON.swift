import Foundation
import Darwin

public enum JSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    public static func write<T: Encodable>(_ value: T, to url: URL, mode: mode_t? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value) + Data([0x0a])
        try data.write(to: url, options: .atomic)
        if let mode {
            chmod(url.path, mode)
        }
    }
}

extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var copy = lhs
        copy.append(rhs)
        return copy
    }
}
