import Darwin
import Foundation

enum StaleProcessCleaner {
    static func terminateProcesses(containing needle: String) {
        let stale = matchingPids(containing: needle)
        guard !stale.isEmpty else { return }

        for pid in stale {
            kill(pid, SIGTERM)
        }
        usleep(300_000)
        for pid in stale where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    private static func matchingPids(containing needle: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", NSRegularExpression.escapedPattern(for: needle)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let currentPid = getpid()
        return output.split(separator: "\n").compactMap { line -> pid_t? in
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid != currentPid else { return nil }
            return pid
        }
    }
}
