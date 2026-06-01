import Foundation
import vEGPUCore

@main
struct VegpuCLI {
    static func main() async {
        let paths = AppPaths()
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            guard args.first == "machine" else {
                printUsage()
                return
            }
            try await runMachine(args: Array(args.dropFirst()), paths: paths)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func runMachine(args: [String], paths: AppPaths) async throws {
        let subcommand = args.first ?? "status"
        let service = MachineService(paths: paths)
        switch subcommand {
        case "paths":
            printJSON([
                "root": paths.root.path,
                "appData": paths.appData.path,
                "machineConfig": paths.machineConfig.path,
                "manifest": paths.manifest.path
            ] as [String: String])
        case "config":
            printJSON(MachineConfigStore(paths: paths).effective())
        case "save-config":
            let current = MachineConfigStore(paths: paths).load()
            let saved = try await service.saveConfig(configFromFlags(Array(args.dropFirst()), current: current))
            printJSON(saved)
        case "manifest":
            printJSON(try ManifestStore(paths: paths).ensure())
        case "status":
            printJSON(await service.statusMachine())
        case "init":
            try await service.initMachine()
            printJSON(OkResponse(ok: true))
        case "start":
            try await service.startMachine()
            printJSON(OkResponse(ok: true))
        case "stop":
            try await service.stopMachine()
            printJSON(OkResponse(ok: true))
        case "reset":
            try await service.resetMachine()
            printJSON(OkResponse(ok: true))
        case "doctor":
            try await service.repairRunningMachine(reason: "manual doctor")
            printJSON(OkResponse(ok: true))
        case "driver-status", "guest-driver-status":
            printJSON(await service.guestDriverStatus())
        case "reinstall-driver":
            printJSON(try await service.reinstallGuestDriver())
        case "install-nvidia":
            printJSON(try await service.installNvidiaStack())
        case "linux-password":
            print(service.linuxPassword() ?? "")
        case "audio-status":
            printJSON(service.audioBridgeStatus())
        case "audio-start":
            let mic = args.dropFirst().contains("--mic")
            let buffer = valueAfter("--buffer-ms", in: Array(args.dropFirst())).flatMap(Int.init) ?? 20
            printJSON(try await service.startAudioBridge(microphoneEnabled: mic, bufferMs: buffer))
        case "audio-stop":
            service.stopAudioBridge()
            printJSON(OkResponse(ok: true))
        case "llms-runtime":
            let output = try await LlmsRuntimeService(paths: paths, machine: service).command(args: Array(args.dropFirst()))
            FileHandle.standardOutput.write(Data(output.utf8))
        default:
            printUsage()
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let data = (try? JSON.encoder.encode(value)) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func configFromFlags(_ args: [String], current: MachineConfig) throws -> MachineConfig {
        var config = current
        var index = 0
        while index < args.count {
            let flag = args[index]
            func value() throws -> String {
                guard index + 1 < args.count else { throw RuntimeError.message("Missing value for \(flag)") }
                index += 1
                return args[index]
            }
            switch flag {
            case "--cpu-mode":
                let raw = try value()
                guard let mode = CpuMode(rawValue: raw) else { throw RuntimeError.message("Invalid CPU mode: \(raw)") }
                config.cpuMode = mode
            case "--cpu":
                config.cpuMode = .manual
                config.cpuCount = Int(try value()) ?? config.cpuCount
            case "--memory-mib", "--memory":
                config.memoryMiB = Int(try value()) ?? config.memoryMiB
            case "--share-root":
                config.shareRoot = try value()
            case "--launch-mode", "--mode":
                let raw = try value()
                guard let mode = RuntimeLaunchMode(rawValue: raw) else { throw RuntimeError.message("Invalid launch mode: \(raw)") }
                config.launchMode = mode
            case "--gui-retina":
                config.guiRetina = try parseBool(value(), flag: flag)
            case "--retina":
                config.guiRetina = true
            case "--no-retina":
                config.guiRetina = false
            case "--gui-resolution-mode":
                let raw = try value()
                guard let mode = GUIResolutionMode(rawValue: raw) else { throw RuntimeError.message("Invalid GUI resolution mode: \(raw)") }
                config.guiResolutionMode = mode
            case "--gui-density":
                let raw = try value()
                guard let density = GUIDensity(rawValue: raw) else { throw RuntimeError.message("Invalid GUI density: \(raw)") }
                config.guiDensity = density
            case "--linux-home-share":
                config.linuxHomeShareEnabled = try parseBool(value(), flag: flag)
            case "--linux-home-mount":
                config.linuxHomeMountPath = try value()
            case "--mac-share-guest-path":
                config.macShareGuestPath = try value()
            case "--start-at-login":
                config.startRuntimeAtLogin = true
            default:
                throw RuntimeError.message("Unknown save-config flag: \(flag)")
            }
            index += 1
        }
        return config
    }

    private static func parseBool(_ raw: String, flag: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw RuntimeError.message("Invalid boolean for \(flag): \(raw)")
        }
    }

    private static func printUsage() {
        print("vegpu machine <status|paths|config|save-config|manifest|init|start|stop|reset|doctor|driver-status|reinstall-driver|install-nvidia|linux-password|audio-status|audio-start|audio-stop|llms-runtime>")
    }

    private static func valueAfter(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

private struct OkResponse: Codable {
    var ok: Bool
}
