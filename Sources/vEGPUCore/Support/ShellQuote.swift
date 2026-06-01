import Foundation

public func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

public func appleScriptQuote(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}

public func firstLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "unknown error"
}

public func base64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

public func base64(_ data: Data) -> String {
    data.base64EncodedString()
}

public func yamlSingleQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}
