import Foundation

public struct MachineFiles: Sendable {
    public let disk: URL
    public let diskSource: URL
    public let efiVars: URL
    public let seedIso: URL
    public let qmp: URL
    public let pid: URL
    public let serialLog: URL
    public let qemuLog: URL
    public let memoryFile: URL
    public let stdoutLog: URL
    public let stderrLog: URL
    public let spiceSocket: URL
    public let audioHostPid: URL
    public let audioHostState: URL
    public let audioHostLog: URL
    public let audioHostErr: URL

    public init(machineDir: URL, liveDir explicitLiveDir: URL? = nil) {
        let liveDir = explicitLiveDir ?? machineDir
        disk = machineDir.appendingPathComponent("disk.qcow2")
        diskSource = machineDir.appendingPathComponent("disk.source.json")
        efiVars = machineDir.appendingPathComponent("efi-vars.fd")
        seedIso = liveDir.appendingPathComponent("seed.iso")
        qmp = liveDir.appendingPathComponent("qmp.sock")
        pid = liveDir.appendingPathComponent("qemu.pid")
        serialLog = liveDir.appendingPathComponent("serial.log")
        qemuLog = liveDir.appendingPathComponent("qemu.log")
        memoryFile = liveDir.appendingPathComponent("memory.bin")
        stdoutLog = liveDir.appendingPathComponent("qemu.stdout.log")
        stderrLog = liveDir.appendingPathComponent("qemu.stderr.log")
        spiceSocket = liveDir.appendingPathComponent("display.spice")
        audioHostPid = liveDir.appendingPathComponent("audio-host.pid")
        audioHostState = liveDir.appendingPathComponent("audio-host.json")
        audioHostLog = liveDir.appendingPathComponent("audio-host.stdout.log")
        audioHostErr = liveDir.appendingPathComponent("audio-host.stderr.log")
    }
}
