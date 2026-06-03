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
    public let qemuOwnerWatchdog: URL
    public let spiceSocket: URL
    public let audioHostPid: URL
    public let audioHostState: URL
    public let audioHostLog: URL
    public let audioHostErr: URL

    public init(machineDir: URL) {
        disk = machineDir.appendingPathComponent("disk.qcow2")
        diskSource = machineDir.appendingPathComponent("disk.source.json")
        efiVars = machineDir.appendingPathComponent("efi-vars.fd")
        seedIso = machineDir.appendingPathComponent("seed.iso")
        qmp = machineDir.appendingPathComponent("qmp.sock")
        pid = machineDir.appendingPathComponent("qemu.pid")
        serialLog = machineDir.appendingPathComponent("serial.log")
        qemuLog = machineDir.appendingPathComponent("qemu.log")
        memoryFile = machineDir.appendingPathComponent("memory.bin")
        stdoutLog = machineDir.appendingPathComponent("qemu.stdout.log")
        stderrLog = machineDir.appendingPathComponent("qemu.stderr.log")
        qemuOwnerWatchdog = machineDir.appendingPathComponent("qemu-owner-watchdog.sh")
        spiceSocket = machineDir.appendingPathComponent("display.spice")
        audioHostPid = machineDir.appendingPathComponent("audio-host.pid")
        audioHostState = machineDir.appendingPathComponent("audio-host.json")
        audioHostLog = machineDir.appendingPathComponent("audio-host.stdout.log")
        audioHostErr = machineDir.appendingPathComponent("audio-host.stderr.log")
    }
}
