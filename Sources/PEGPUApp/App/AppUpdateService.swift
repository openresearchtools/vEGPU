import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

@MainActor
final class AppUpdateService: ObservableObject {
    enum Channel: String, CaseIterable {
        case stable
        case prerelease

        var title: String {
            switch self {
            case .stable: return "Stable Releases"
            case .prerelease: return "Pre-release Updates"
            }
        }

        var manifestURL: URL {
            switch self {
            case .stable:
                return URL(string: "https://raw.githubusercontent.com/openresearchtools/PEGPU/main/releases/releases-manifest.json")!
            case .prerelease:
                return URL(string: "https://raw.githubusercontent.com/openresearchtools/PEGPU/main/releases/pre-releases-manifest.json")!
            }
        }
    }

    struct Manifest: Decodable {
        var schemaVersion: Int
        var channel: String
        var updatedAt: String
        var latest: Entry?
        var items: [Entry]
    }

    struct Entry: Decodable, Identifiable {
        var id: String { tag }
        var version: String
        var build: String
        var tag: String
        var name: String
        var prerelease: Bool
        var publishedAt: String
        var releasePageURL: URL
        var packageURL: URL
        var packageName: String
        var packageSize: Int64
        var packageSHA256: String
        var minimumMacOS: String

        private enum CodingKeys: String, CodingKey {
            case version
            case build
            case tag
            case name
            case prerelease
            case publishedAt
            case releasePageURL
            case packageURL
            case packageName
            case packageSize
            case packageSHA256
            case minimumMacOS
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(String.self, forKey: .version)
            build = try values.decode(FlexibleString.self, forKey: .build).value
            tag = try values.decode(String.self, forKey: .tag)
            name = try values.decode(String.self, forKey: .name)
            prerelease = try values.decode(Bool.self, forKey: .prerelease)
            publishedAt = try values.decode(String.self, forKey: .publishedAt)
            releasePageURL = try values.decode(URL.self, forKey: .releasePageURL)
            packageURL = try values.decode(URL.self, forKey: .packageURL)
            packageName = try values.decode(String.self, forKey: .packageName)
            packageSize = try values.decodeIfPresent(Int64.self, forKey: .packageSize) ?? 0
            packageSHA256 = try values.decodeIfPresent(String.self, forKey: .packageSHA256) ?? ""
            minimumMacOS = try values.decodeIfPresent(String.self, forKey: .minimumMacOS) ?? "13.5"
        }
    }

    @Published private(set) var channel: Channel
    @Published private(set) var availableUpdate: Entry?
    @Published private(set) var statusText = "Updates not checked"
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false

    private let defaults: UserDefaults
    private let updatesDir: URL
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        let raw = defaults.string(forKey: PreferencesKeys.updateChannel) ?? Channel.stable.rawValue
        self.channel = Channel(rawValue: raw) ?? .stable
        self.updatesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PEGPU/Updates", isDirectory: true)
    }

    func setChannel(_ next: Channel) {
        channel = next
        defaults.set(next.rawValue, forKey: PreferencesKeys.updateChannel)
        availableUpdate = nil
        statusText = "Using \(next.title)"
    }

    func togglePrerelease() {
        setChannel(channel == .prerelease ? .stable : .prerelease)
    }

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        if !silent {
            statusText = "Checking \(channel.title)..."
        }
        defer { isChecking = false }
        do {
            let manifest = try await fetchManifest()
            let update = newestAvailableUpdate(from: manifest)
            availableUpdate = update
            if let update {
                statusText = "Update available: v\(update.version)"
            } else {
                statusText = "PEGPU is up to date"
            }
        } catch {
            if !silent {
                statusText = "Update check failed: \(Self.shortError(error))"
            }
        }
    }

    func refreshAndReturnAvailableUpdate() async throws -> Entry? {
        let manifest = try await fetchManifest()
        let update = newestAvailableUpdate(from: manifest)
        availableUpdate = update
        statusText = update.map { "Update available: v\($0.version)" } ?? "PEGPU is up to date"
        return update
    }

    func downloadPackage(for update: Entry) async throws -> URL {
        guard !isDownloading else {
            throw AppUpdateError.message("An update download is already running.")
        }
        isDownloading = true
        statusText = "Downloading \(update.packageName)..."
        defer { isDownloading = false }

        try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let (temporaryURL, response) = try await session.download(from: update.packageURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.message("Download failed for \(update.packageName).")
        }

        let destination = updatesDir.appendingPathComponent(safePackageName(update.packageName))
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        if update.packageSize > 0 {
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if Int64(size) != update.packageSize {
                throw AppUpdateError.message("Downloaded package size did not match the release manifest.")
            }
        }
        if !update.packageSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let actual = try sha256Hex(of: destination)
            if actual.caseInsensitiveCompare(update.packageSHA256) != .orderedSame {
                throw AppUpdateError.message("Downloaded package SHA-256 did not match the release manifest.")
            }
        }

        chmod(destination.path, 0o644)
        try runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path], tolerateFailure: true)
        statusText = "Downloaded \(update.packageName)"
        return destination
    }

    func openInstaller(packageURL: URL) throws {
        guard NSWorkspace.shared.open(packageURL) else {
            throw AppUpdateError.message("Could not open \(packageURL.lastPathComponent) in Installer.app.")
        }
    }

    private func fetchManifest() async throws -> Manifest {
        var request = URLRequest(url: channel.manifestURL)
        request.setValue("PEGPU/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.message("Update manifest was not reachable.")
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func newestAvailableUpdate(from manifest: Manifest) -> Entry? {
        let candidates = ([manifest.latest].compactMap { $0 } + manifest.items)
            .filter { isCompatible(minimumMacOS: $0.minimumMacOS) }
            .filter { Self.isNewer(version: $0.version, build: $0.build) }
        return candidates.sorted { lhs, rhs in
            if Self.compareVersion(lhs.version, rhs.version) == .orderedSame {
                return Self.compareBuild(lhs.build, rhs.build) == .orderedDescending
            }
            return Self.compareVersion(lhs.version, rhs.version) == .orderedDescending
        }.first
    }

    private func isCompatible(minimumMacOS: String) -> Bool {
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let currentText = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        return Self.compareVersion(currentText, minimumMacOS) != .orderedAscending
    }

    private func safePackageName(_ name: String) -> String {
        let clean = name
            .split(separator: "/")
            .last
            .map(String.init) ?? "PEGPU-update.pkg"
        if clean.hasSuffix(".pkg") {
            return clean
        }
        return "PEGPU-update.pkg"
    }

    private func runTool(_ executable: String, _ arguments: [String], tolerateFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !tolerateFailure {
            throw AppUpdateError.message("\(executable) failed with exit \(process.terminationStatus).")
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private static func isNewer(version: String, build: String) -> Bool {
        switch compareVersion(version, currentVersion) {
        case .orderedDescending:
            return true
        case .orderedAscending:
            return false
        case .orderedSame:
            return compareBuild(build, currentBuild) == .orderedDescending
        }
    }

    private static func compareBuild(_ lhs: String, _ rhs: String) -> ComparisonResult {
        compareVersion(lhs, rhs)
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a == b { continue }
            return a < b ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func versionParts(_ value: String) -> [Int] {
        value
            .split { !$0.isNumber }
            .map { Int($0) ?? 0 }
    }

    private static func shortError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private struct FlexibleString: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(Int(double))
        } else {
            value = ""
        }
    }
}

private enum AppUpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): return message
        }
    }
}
