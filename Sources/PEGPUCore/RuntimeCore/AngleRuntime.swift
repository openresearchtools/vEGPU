import Foundation

public enum AngleRuntime {
    public static let requiredFrameworkNames = ["EGL", "GLESv2"]

    public static func frameworkDirectory(
        root: URL = AppPaths.discoverRoot(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        for candidate in candidateFrameworkDirectories(root: root, environment: environment) {
            let url = candidate.standardizedFileURL
            if missingFrameworkNames(in: url).isEmpty {
                return url
            }
        }
        return nil
    }

    public static func missingFrameworkNames(in directory: URL) -> [String] {
        requiredFrameworkNames.filter { name in
            let framework = directory.appendingPathComponent("\(name).framework", isDirectory: true)
            let topLevelBinary = framework.appendingPathComponent(name).path
            let versionedBinary = framework
                .appendingPathComponent("Versions/Current", isDirectory: true)
                .appendingPathComponent(name)
                .path
            return !FileManager.default.fileExists(atPath: topLevelBinary)
                && !FileManager.default.fileExists(atPath: versionedBinary)
        }
    }

    public static func candidateFrameworkDirectories(
        root: URL = AppPaths.discoverRoot(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard !standardized.path.isEmpty, seen.insert(standardized.path).inserted else { return }
            candidates.append(standardized)
        }

        if let override = environment["PEGPU_ANGLE_FRAMEWORK_DIR"], !override.isEmpty {
            append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let override = environment["PEGPU_DISPLAY_FRAMEWORKS_OUT"], !override.isEmpty {
            append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let override = environment["PEGPU_DISPLAY_FRAMEWORKS_DIR"], !override.isEmpty {
            append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        append(Bundle.main.privateFrameworksURL)
        append(Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true))
        if let resourceURL = Bundle.main.resourceURL {
            append(resourceURL.deletingLastPathComponent().appendingPathComponent("Frameworks", isDirectory: true))
        }
        append(root
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks", isDirectory: true))

        return candidates
    }
}
