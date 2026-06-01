import Foundation
import Security

public struct MachineSecrets: Codable, Equatable, Sendable {
    public let linuxPassword: String

    public init(linuxPassword: String) {
        self.linuxPassword = linuxPassword
    }
}

public final class SecretsStore: @unchecked Sendable {
    private let paths: AppPaths
    private var url: URL { paths.appData.appendingPathComponent("secrets.json") }

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func read() -> MachineSecrets? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MachineSecrets.self, from: data)
    }

    public func ensure() throws -> MachineSecrets {
        if let existing = read() {
            return existing
        }
        let secrets = MachineSecrets(linuxPassword: generatePassword())
        try save(secrets)
        return secrets
    }

    public func save(_ secrets: MachineSecrets) throws {
        try JSON.write(secrets, to: url, mode: 0o600)
    }

    private func generatePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
