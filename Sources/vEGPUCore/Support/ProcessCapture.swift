import Foundation

extension Process {
    static func runAndCapture(_ executable: String, _ arguments: [String]) throws -> String {
        let workingDirectory = try ProcessLaunchSupport.workingDirectory(nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
