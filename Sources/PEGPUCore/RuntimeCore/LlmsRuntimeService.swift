import CryptoKit
import Foundation

public final class LlmsRuntimeService: @unchecked Sendable {
    private let paths: AppPaths
    private let machine: MachineService
    private let ssh: SSHClient
    private let share: NFSShareService
    private let configStore: MachineConfigStore
    private let runner = ProcessRunner()

    private let childRunDir = "/var/tmp/pegpu-llms/run"
    private let childLogDir = "/var/tmp/pegpu-llms/log"
    private let defaultPath = "/usr/local/bin:/usr/bin:/bin:/usr/local/cuda/bin"
    private let guestLlamaServer = "/usr/local/bin/llama-server"
    private let guestRPCServer = "/usr/local/bin/rpc-server"
    private let guestRuntimeRoot = "/home/pegpu/custom-llama-runtimes"
    private let guestHFRoot = "/home/pegpu/.cache/huggingface/hub"
    private let guestLMStudioRoot = "/home/pegpu/.lmstudio/models"

    private var stateDir: URL { paths.appData.appendingPathComponent("ai/llms", isDirectory: true) }
    private var directStateFile: URL { stateDir.appendingPathComponent("vm-direct-runtime.json") }

    public init(paths: AppPaths = AppPaths(), machine: MachineService? = nil) {
        self.paths = paths
        let networkStore = NetworkStateStore(paths: paths)
        self.ssh = SSHClient(paths: paths, networkStore: networkStore)
        self.share = NFSShareService(paths: paths, ssh: ssh)
        self.configStore = MachineConfigStore(paths: paths)
        self.machine = machine ?? MachineService(paths: paths)
    }

    public func command(args: [String]) async throws -> String {
        let sub = args.first?.lowercased()
        let value = args.dropFirst().first
        switch sub {
        case "ensure", "ensure-services":
            try await ensureDirectRuntime()
            return try encode(OkModeResponse(ok: true, mode: "direct-vm"))
        case "install-runtime":
            return try encode(await installRuntime(spec: loadInstallSpec(value)))
        case "runtime-installed":
            guard let id = value else { throw RuntimeError.message("usage: pegpu machine llms-runtime runtime-installed <runtime-id>") }
            return try encode(await runtimeInstalled(id: id))
        case "delete-runtime":
            guard let id = value else { throw RuntimeError.message("usage: pegpu machine llms-runtime delete-runtime <runtime-id>") }
            try await deleteInstalledRuntime(id: id)
            return try encode(StopResponse(ok: true, id: id))
        case "start-server":
            return try encode(await startChild(role: "server", spec: loadSpec(value)))
        case "start-rpc":
            return try encode(await startChild(role: "rpc", spec: loadSpec(value)))
        case "list-devices":
            let devices = try await listDevices(spec: value.map(loadSpec) ?? LlmsRuntimeSpec())
            return try encode(DeviceList(devices: devices))
        case "list-devices-if-running":
            let devices = machine.currentPid() == nil ? [] : try await listDevices(spec: value.map(loadSpec) ?? LlmsRuntimeSpec())
            return try encode(DeviceList(devices: devices))
        case "list-models":
            return try encode(LlmsModelList(models: try await listModels()))
        case "list-models-if-running":
            let models = machine.currentPid() == nil ? [] : try await listModels()
            return try encode(LlmsModelList(models: models))
        case "download-hf":
            try await downloadHF(spec: loadHFDownloadSpec(value))
            return try encode(OkResponse(ok: true))
        case "copy-model":
            return try encode(try await copyModel(spec: loadModelCopySpec(value)))
        case "stop":
            guard let id = value else { throw RuntimeError.message("usage: pegpu machine llms-runtime stop <runtime-id>") }
            try await stopChild(id: id)
            return try encode(StopResponse(ok: true, id: id))
        case "tail-log":
            guard let id = value else { throw RuntimeError.message("usage: pegpu machine llms-runtime tail-log <runtime-id>") }
            return try await tailChildLog(id: id) + "\n"
        case "stop-servers":
            try await stopServerChildren()
            return try encode(OkResponse(ok: true))
        case "status":
            return try encode(await status())
        default:
            return "usage: pegpu machine llms-runtime <ensure|install-runtime|runtime-installed|delete-runtime|start-server|start-rpc|list-devices|list-devices-if-running|list-models|list-models-if-running|download-hf|copy-model|tail-log|stop|stop-servers|status> [json-spec|runtime-id]\n"
        }
    }

    public func startChild(role: String, spec: LlmsRuntimeSpec) async throws -> RuntimeResult {
        try await ensureDirectRuntime()
        let shareRoot = normalizeShareRoot(configStore.effective().shareRoot)
        try validateSpecPaths(spec, shareRoot: shareRoot)
        try await ensureShareForSpec(spec, shareRoot: shareRoot)

        let id = childId(role: role, spec: spec)
        let port = validPort(spec.port) ?? (role == "server" ? 8080 : 50052)
        let command = spec.command ?? (role == "server" ? guestLlamaServer : guestRPCServer)
        let args = ensureBindArgs(args: mapArgs(spec.args ?? [], shareRoot: shareRoot), port: port)
        _ = try? await ssh.agent(["apply-private-port", String(port), "tcp"], timeout: 10)

        let pidFile = "\(childRunDir)/\(id).pid"
        let logFile = "\(childLogDir)/\(id).log"
        let script = ([
            "set -eu",
            "mkdir -p \(shellQuote(childRunDir)) \(shellQuote(childLogDir))",
            stopPidScript(pidFile),
            ": > \(shellQuote(logFile))",
            "export PATH=\(shellQuote(defaultPath)):$PATH"
        ] + normalizeEnv(spec.env ?? []) + [
            "(\(([command] + args).map(shellQuote).joined(separator: " "))) >> \(shellQuote(logFile)) 2>&1 &",
            "pid=$!",
            "printf '%s\\n' \"$pid\" > \(shellQuote(pidFile))",
            "sleep 0.5",
            "if ! kill -0 \"$pid\" 2>/dev/null; then tail -n 100 \(shellQuote(logFile)) >&2 || true; exit 1; fi"
        ]).joined(separator: "\n")
        _ = try await runGuestScript(script, timeout: 20)
        let result = RuntimeResult(
            id: id,
            role: role,
            host: VMNet.guestIP,
            baseUrl: role == "server" ? "http://\(VMNet.guestIP):\(port)" : nil,
            endpoint: role == "rpc" ? "\(VMNet.guestIP):\(port)" : nil,
            port: port,
            pidFile: pidFile,
            logFile: logFile
        )
        try writeState(DirectRuntimeState(mode: "direct-vm", shareRoot: shareRoot))
        return result
    }

    public func listDevices(spec: LlmsRuntimeSpec) async throws -> [LlamaDevice] {
        try await ensureDirectRuntime()
        let command = spec.command ?? guestLlamaServer
        let script = ([
            "set -eu",
            "export PATH=\(shellQuote(defaultPath)):$PATH"
        ] + normalizeEnv(spec.env ?? []) + [
            "exec \(shellQuote(command)) --list-devices"
        ]).joined(separator: "\n")
        let out = try await runGuestScript(script, timeout: 20)
        let nvidia = (try? await queryNvidiaDevices()) ?? []
        let vulkan = (try? await queryVulkanDevices()) ?? []
        return annotateLlamaDevices(parseLlamaDevices(out), nvidia: nvidia, vulkan: vulkan)
            .filter { isVMAcceleratorBackend($0.backend) }
    }

    public func stopChild(id: String) async throws {
        guard machine.currentPid() != nil else { return }
        try await ssh.waitForSSH(timeout: 15)
        let safe = safeName(id)
        let pidFile = "\(childRunDir)/\(safe).pid"
        _ = try? await runGuestScript([stopPidScript(pidFile), "rm -f \(shellQuote(pidFile))"].joined(separator: "\n"), timeout: 10)
    }

    public func stopServerChildren() async throws {
        guard machine.currentPid() != nil else { return }
        try await ssh.waitForSSH(timeout: 15)
        let script = """
        for pidFile in \(shellQuote(childRunDir))/server-*.pid; do
          [ -e "$pidFile" ] || continue
          pid="$(cat "$pidFile" 2>/dev/null || true)"
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
          fi
          rm -f "$pidFile"
        done
        """
        _ = try? await runGuestScript(script, timeout: 8)
    }

    public func tailChildLog(id: String) async throws -> String {
        try await ensureDirectRuntime()
        return (try? await runGuestScript("tail -n 160 \(shellQuote("\(childLogDir)/\(safeName(id)).log")) 2>/dev/null || true", timeout: 10)) ?? ""
    }

    public func status() async -> LlmsRuntimeStatus {
        guard machine.currentPid() != nil else {
            return LlmsRuntimeStatus(running: false, mode: "direct-vm", state: readState(), children: [])
        }
        try? await ssh.waitForSSH(timeout: 15)
        let script = "ls -1 \(shellQuote(childRunDir))/*.pid 2>/dev/null | xargs -r -n1 sh -c 'p=\"$(cat \"$0\" 2>/dev/null || true)\"; kill -0 \"$p\" 2>/dev/null && echo \"$0:$p:running\" || echo \"$0:$p:stopped\"'"
        let children = ((try? await runGuestScript(script, timeout: 10)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        return LlmsRuntimeStatus(running: true, mode: "direct-vm", state: readState(), children: children)
    }

    public func listModels() async throws -> [LlmsModelInfo] {
        guard machine.currentPid() != nil else { return [] }
        try await ssh.waitForSSH(timeout: 10)
        let script = """
        sudo -n -u pegpu python3 - <<'PY'
        import hashlib, json, os, re

        roots = [
            ("huggingface", "/home/pegpu/.cache/huggingface/hub"),
            ("lmstudio", "/home/pegpu/.lmstudio/models"),
        ]

        def sanitize(raw):
            raw = raw.strip().lower()
            out = []
            last_dash = False
            for ch in raw:
                ok = ("a" <= ch <= "z") or ("0" <= ch <= "9")
                if ok:
                    out.append(ch)
                    last_dash = False
                elif not last_dash:
                    out.append("-")
                    last_dash = True
            value = "".join(out).strip("-")
            if not value:
                value = "model-" + hashlib.sha1(raw.encode()).hexdigest()[:10]
            if len(value) > 140:
                value = value[:100] + "-" + hashlib.sha1(value.encode()).hexdigest()[:10]
            return value

        def source_for(path, provider, root):
            slash = path.replace(os.sep, "/")
            if provider == "huggingface":
                for part in slash.split("/"):
                    if part.startswith("models--"):
                        return part[len("models--"):].replace("--", "/")
            if provider == "lmstudio":
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                parts = rel.split("/")
                return "/".join(parts[:2]) if len(parts) >= 2 else rel
            return os.path.dirname(path)

        def display_name(path, provider, source):
            base = os.path.splitext(os.path.basename(path))[0]
            if provider == "huggingface" and "/" in source:
                return source + ":" + base
            return base

        def is_mmproj(name):
            lower = name.lower()
            return "mmproj" in lower or lower.endswith(".mmproj")

        def looks_like_gguf(path):
            try:
                with open(path, "rb") as fh:
                    return fh.read(4) == b"GGUF"
            except Exception:
                return False

        def keep_meta_key(key):
            key = key.lower()
            return (
                key in ("general.architecture", "general.name", "general.basename", "general.description", "general.type")
                or key.endswith(".context_length")
                or key.endswith(".block_count")
                or key.endswith(".embedding_length")
            )

        def read_str(fh):
            raw = fh.read(8)
            if len(raw) != 8:
                raise EOFError()
            size = int.from_bytes(raw, "little")
            data = fh.read(size)
            if len(data) != size:
                raise EOFError()
            return data.decode("utf-8", "replace")

        def read_scalar(fh, typ):
            import struct
            sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
            if typ == 8:
                return read_str(fh)
            if typ not in sizes:
                return None
            data = fh.read(sizes[typ])
            if len(data) != sizes[typ]:
                raise EOFError()
            if typ == 7:
                return "true" if data != b"\\x00" else "false"
            fmts = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 10: "<Q", 11: "<q", 12: "<d"}
            value = struct.unpack(fmts[typ], data)[0]
            return str(value)

        def skip_value(fh, typ):
            sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
            if typ == 8:
                read_str(fh)
                return
            if typ == 9:
                elem = int.from_bytes(fh.read(4), "little")
                count = int.from_bytes(fh.read(8), "little")
                for _ in range(count):
                    skip_value(fh, elem)
                return
            if typ not in sizes:
                raise EOFError()
            fh.seek(sizes[typ], 1)

        def read_metadata(path):
            meta = {"format": "GGUF"}
            try:
                with open(path, "rb") as fh:
                    if fh.read(4) != b"GGUF":
                        return meta
                    fh.read(4)
                    fh.read(8)
                    count = int.from_bytes(fh.read(8), "little")
                    for _ in range(count):
                        key = read_str(fh)
                        typ = int.from_bytes(fh.read(4), "little")
                        if keep_meta_key(key):
                            value = read_scalar(fh, typ)
                            if value is not None:
                                meta[key] = value
                            else:
                                skip_value(fh, typ)
                        else:
                            skip_value(fh, typ)
            except Exception:
                pass
            return meta

        split_re = re.compile(r"(?i)^(.+)-([0-9]{5})-of-([0-9]{5})\\.gguf$")

        models = []
        seen = set()
        for provider, root in roots:
            if not os.path.isdir(root):
                continue
            mmproj_by_dir = {}
            model_paths = []
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
                for filename in filenames:
                    lower = filename.lower()
                    path = os.path.join(dirpath, filename)
                    if is_mmproj(lower):
                        mmproj_by_dir.setdefault(dirpath, []).append(path)
                        continue
                    if not lower.endswith(".gguf"):
                        continue
                    match = split_re.match(filename)
                    if match and int(match.group(2)) > 1:
                        continue
                    if looks_like_gguf(path):
                        model_paths.append(path)
            for values in mmproj_by_dir.values():
                values.sort()
            for path in model_paths:
                real = os.path.realpath(path)
                if real in seen:
                    continue
                seen.add(real)
                source = source_for(path, provider, root)
                name = display_name(path, provider, source)
                model_dir = os.path.dirname(path)
                mmproj = ""
                candidates = list(mmproj_by_dir.get(model_dir, []))
                parent = os.path.dirname(model_dir)
                candidates += mmproj_by_dir.get(parent, [])
                if candidates:
                    base = os.path.splitext(os.path.basename(path).lower())[0]
                    def score(candidate):
                        cb = os.path.splitext(os.path.basename(candidate).lower())[0]
                        if cb == "mmproj-" + base or cb == base:
                            return 0
                        if base in cb or cb.replace("mmproj-", "") in base:
                            return 1
                        if cb.startswith("mmproj"):
                            return 2
                        return 9
                    candidates.sort(key=lambda item: (score(item), len(item)))
                    if score(candidates[0]) < 9:
                        mmproj = candidates[0]
                try:
                    size = os.path.getsize(path)
                except OSError:
                    size = 0
                metadata = read_metadata(path)
                models.append({
                    "id": sanitize(provider + "-" + source + "-" + os.path.basename(path)),
                    "name": name,
                    "provider": provider,
                    "source": source,
                    "location": "vm",
                    "format": "GGUF",
                    "modelPath": path,
                    "mmprojPath": mmproj or None,
                    "sizeBytes": size,
                    "metadata": metadata,
                })
        print(json.dumps({"models": models}, separators=(",", ":")))
        PY
        """
        let out = try await runGuestScript(script, timeout: 30)
        return try JSON.decoder.decode(LlmsModelList.self, from: Data(out.utf8)).models
    }

    public func downloadHF(spec: LlmsHFDownloadSpec) async throws {
        guard machine.currentPid() != nil else {
            throw RuntimeError.message("PEGPU runtime is not running. Start the runtime before downloading into the VM.")
        }
        let repo = spec.repo.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard repo.split(separator: "/").count >= 2 else {
            throw RuntimeError.message("Hugging Face repo must be org/model")
        }
        let revision = (spec.revision?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        let paths = try spec.paths.map { try normalizedHFPath($0) }
        guard !paths.isEmpty else {
            throw RuntimeError.message("at least one Hugging Face path is required")
        }
        try await ssh.waitForSSH()
        let token = (spec.token?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let tokenHeader = token.map { "Authorization: Bearer \($0)" }
        let repoDir = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let sizes = await hfRemoteSizes(repo: repo, revision: revision, paths: paths, token: token)
        let totalBytes = sizes.values.reduce(Int64(0), +)
        var downloadedBytes: Int64 = 0
        writeModelCopyProgress(spec.progressPath, status: "running", current: nil, copiedBytes: downloadedBytes, totalBytes: totalBytes)
        let setupScript = [
            "set -eu",
            "sudo -n -u pegpu install -d -m 0755 \(shellQuote("\(guestHFRoot)/\(repoDir)/snapshots/\(revision)"))"
        ].joined(separator: "\n")
        _ = try await runGuestScript(setupScript, timeout: 20)
        for remotePath in paths {
            let target = "\(guestHFRoot)/\(repoDir)/snapshots/\(revision)/\(remotePath)"
            let url = hfResolveURL(repo: repo, revision: revision, path: remotePath)
            let headerArgs = tokenHeader.map { "-H \(shellQuote($0)) " } ?? ""
            let temp = target + ".part"
            let knownSize = sizes[remotePath] ?? 0
            var scriptLines = [
                "set -eu",
                "sudo -n -u pegpu install -d -m 0755 \(shellQuote(URL(fileURLWithPath: target).deletingLastPathComponent().path))",
            ]
            if spec.restart == true {
                scriptLines.append("sudo -n -u pegpu rm -f \(shellQuote(temp)) \(shellQuote(target))")
            }
            if knownSize > 0 {
                scriptLines.append("if [ -f \(shellQuote(target)) ] && [ \"$(stat -c %s \(shellQuote(target)) 2>/dev/null || echo 0)\" = \(knownSize) ]; then exit 0; fi")
                scriptLines.append("if [ -f \(shellQuote(temp)) ] && [ \"$(stat -c %s \(shellQuote(temp)) 2>/dev/null || echo 0)\" -gt \(knownSize) ]; then sudo -n -u pegpu rm -f \(shellQuote(temp)); fi")
            } else {
                scriptLines.append("if [ -f \(shellQuote(target)) ]; then exit 0; fi")
            }
            scriptLines.append("sudo -n -u pegpu sh -lc \(shellQuote("curl -L --fail --connect-timeout 30 --retry 999999 --retry-delay 2 --retry-all-errors --speed-limit 1024 --speed-time 90 -C - \(headerArgs)-o \(shellQuote(temp)) \(shellQuote(url))"))")
            scriptLines.append("sudo -n -u pegpu mv \(shellQuote(temp)) \(shellQuote(target))")
            let script = scriptLines.joined(separator: "\n")
            let poller = startRemoteSizeProgress(
                remotePath: temp,
                baseBytes: downloadedBytes,
                totalBytes: totalBytes,
                current: remotePath,
                progressPath: spec.progressPath
            )
            do {
                _ = try await runGuestScript(script)
            } catch {
                poller?.cancel()
                throw error
            }
            poller?.cancel()
            let expectedSize = sizes[remotePath] ?? 0
            let actualSize = (try? await guestFileSizes([target]))?[target] ?? 0
            downloadedBytes += expectedSize > 0 ? expectedSize : actualSize
            writeModelCopyProgress(spec.progressPath, status: "running", current: remotePath, copiedBytes: downloadedBytes, totalBytes: totalBytes)
        }
        writeModelCopyProgress(spec.progressPath, status: "complete", current: nil, copiedBytes: downloadedBytes, totalBytes: totalBytes)
    }

    private func hfRemoteSizes(repo: String, revision: String, paths: [String], token: String?) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for path in paths {
            guard let url = URL(string: hfResolveURL(repo: repo, revision: revision, path: path)) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "HEAD"
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<400).contains(http.statusCode),
                      let value = http.value(forHTTPHeaderField: "Content-Length"),
                      let size = Int64(value) else {
                    continue
                }
                sizes[path] = size
            } catch {
                continue
            }
        }
        return sizes
    }

    public func copyModel(spec: LlmsModelCopySpec) async throws -> LlmsModelCopyResult {
        let sourceLocation = spec.sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard sourceLocation == "mac" || sourceLocation == "vm" else {
            throw RuntimeError.message("model copy sourceLocation must be mac or vm")
        }
        let files = spec.files.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !files.isEmpty else {
            throw RuntimeError.message("model copy requires at least one file")
        }
        let macRoot = spec.macRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let vmRoot = spec.vmRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !macRoot.isEmpty, !vmRoot.isEmpty else {
            throw RuntimeError.message("model copy requires Mac and VM roots")
        }
        guard machine.currentPid() != nil else {
            throw RuntimeError.message("PEGPU runtime is not running. Start the runtime before copying VM models.")
        }
        try await ssh.waitForSSH()
        return sourceLocation == "mac"
            ? try await copyMacModelToVM(files: files, macRoot: macRoot, vmRoot: vmRoot, progressPath: spec.progressPath)
            : try await copyVMModelToMac(files: files, macRoot: macRoot, vmRoot: vmRoot, progressPath: spec.progressPath)
    }

    private func copyMacModelToVM(files: [String], macRoot: String, vmRoot: String, progressPath: String?) async throws -> LlmsModelCopyResult {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let remoteDir = "/var/tmp/pegpu-model-copy-\(token)"
        _ = try await runGuestScript("sudo -n rm -rf \(shellQuote(remoteDir)); sudo -n install -d -m 0777 \(shellQuote(remoteDir))", timeout: 10)
        defer {
            Task { try? await self.runGuestScript("sudo -n rm -rf \(shellQuote(remoteDir))", timeout: 10) }
        }
        var copied: [String] = []
        let sizes = Dictionary(uniqueKeysWithValues: files.map { ($0, localFileSize($0)) })
        let totalBytes = sizes.values.reduce(Int64(0), +)
        var copiedBytes: Int64 = 0
        writeModelCopyProgress(progressPath, status: "running", current: nil, copiedBytes: copiedBytes, totalBytes: totalBytes)
        for (index, file) in files.enumerated() {
            let rel = try relativeChildPath(file, under: macRoot)
            let destination = "\(vmRoot)/\(rel)"
            let remoteTemp = "\(remoteDir)/file-\(index)"
            let fileSize = sizes[file] ?? 0
            let poller = startRemoteSizeProgress(remotePath: remoteTemp, baseBytes: copiedBytes, totalBytes: totalBytes, current: file, progressPath: progressPath)
            do {
                try await ssh.scpToGuest(localPath: file, remotePath: remoteTemp)
            } catch {
                poller?.cancel()
                throw error
            }
            poller?.cancel()
            let script = """
            set -eu
            sudo -n install -d -o pegpu -g pegpu -m 0755 \(shellQuote(URL(fileURLWithPath: destination).deletingLastPathComponent().path))
            sudo -n install -o pegpu -g pegpu -m 0644 \(shellQuote(remoteTemp)) \(shellQuote(destination))
            rm -f \(shellQuote(remoteTemp))
            """
            _ = try await runGuestScript(script, timeout: 120)
            copiedBytes += fileSize
            writeModelCopyProgress(progressPath, status: "running", current: file, copiedBytes: copiedBytes, totalBytes: totalBytes)
            copied.append(destination)
        }
        writeModelCopyProgress(progressPath, status: "complete", current: nil, copiedBytes: copiedBytes, totalBytes: totalBytes)
        return LlmsModelCopyResult(copied: copied)
    }

    private func copyVMModelToMac(files: [String], macRoot: String, vmRoot: String, progressPath: String?) async throws -> LlmsModelCopyResult {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let remoteDir = "/var/tmp/pegpu-model-copy-\(token)"
        _ = try await runGuestScript("sudo -n rm -rf \(shellQuote(remoteDir)); sudo -n install -d -m 0777 \(shellQuote(remoteDir))", timeout: 10)
        defer {
            Task { try? await self.runGuestScript("sudo -n rm -rf \(shellQuote(remoteDir))", timeout: 10) }
        }
        var copied: [String] = []
        let localTempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pegpu-model-copy-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: localTempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localTempRoot) }
        let sizes = try await guestFileSizes(files)
        let totalBytes = sizes.values.reduce(Int64(0), +)
        var copiedBytes: Int64 = 0
        writeModelCopyProgress(progressPath, status: "running", current: nil, copiedBytes: copiedBytes, totalBytes: totalBytes)
        for (index, file) in files.enumerated() {
            let rel = try relativeChildPath(file, under: vmRoot)
            let destination = URL(fileURLWithPath: macRoot).appendingPathComponent(rel)
            let remoteTemp = "\(remoteDir)/file-\(index)"
            let fileSize = sizes[file] ?? 0
            let script = """
            set -eu
            sudo -n -u pegpu test -f \(shellQuote(file))
            sudo -n -u pegpu cp \(shellQuote(file)) \(shellQuote(remoteTemp))
            sudo -n chmod 0644 \(shellQuote(remoteTemp))
            """
            writeModelCopyProgress(progressPath, status: "running", current: file, copiedBytes: copiedBytes, totalBytes: totalBytes)
            _ = try await runGuestScript(script, timeout: 120)
            let localTemp = localTempRoot.appendingPathComponent("file-\(index)")
            let poller = startLocalSizeProgress(localPath: localTemp.path, baseBytes: copiedBytes, totalBytes: totalBytes, current: file, progressPath: progressPath)
            do {
                try await ssh.scpFromGuest(remotePath: remoteTemp, localPath: localTemp.path)
            } catch {
                poller?.cancel()
                throw error
            }
            poller?.cancel()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: localTemp, to: destination)
            _ = try? await runGuestScript("rm -f \(shellQuote(remoteTemp))", timeout: 10)
            copiedBytes += fileSize
            writeModelCopyProgress(progressPath, status: "running", current: file, copiedBytes: copiedBytes, totalBytes: totalBytes)
            copied.append(destination.path)
        }
        writeModelCopyProgress(progressPath, status: "complete", current: nil, copiedBytes: copiedBytes, totalBytes: totalBytes)
        return LlmsModelCopyResult(copied: copied)
    }

    private func localFileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func guestFileSizes(_ files: [String]) async throws -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for file in files {
            let out = try await runGuestScript("sudo -n -u pegpu stat -c %s \(shellQuote(file))", timeout: 10)
            sizes[file] = Int64(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return sizes
    }

    private func startRemoteSizeProgress(remotePath: String, baseBytes: Int64, totalBytes: Int64, current: String, progressPath: String?) -> Task<Void, Never>? {
        guard let progressPath, !progressPath.isEmpty else { return nil }
        return Task { [weak self] in
            while !Task.isCancelled {
                let out = try? await self?.runGuestScript("stat -c %s \(shellQuote(remotePath)) 2>/dev/null || echo 0", timeout: 5)
                let size = Int64(out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                self?.writeModelCopyProgress(progressPath, status: "running", current: current, copiedBytes: baseBytes + size, totalBytes: totalBytes)
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func startLocalSizeProgress(localPath: String, baseBytes: Int64, totalBytes: Int64, current: String, progressPath: String?) -> Task<Void, Never>? {
        guard let progressPath, !progressPath.isEmpty else { return nil }
        return Task { [weak self] in
            while !Task.isCancelled {
                let size = self?.localFileSize(localPath) ?? 0
                self?.writeModelCopyProgress(progressPath, status: "running", current: current, copiedBytes: baseBytes + size, totalBytes: totalBytes)
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func writeModelCopyProgress(_ path: String?, status: String, current: String?, copiedBytes: Int64, totalBytes: Int64) {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let progress = LlmsModelCopyProgress(status: status, current: current, copiedBytes: copiedBytes, totalBytes: totalBytes)
        guard let data = try? JSON.encoder.encode(progress) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func ensureDirectRuntime() async throws {
        guard machine.currentPid() != nil else {
            throw RuntimeError.message("PEGPU runtime is not running. Start the runtime before using VM accelerator devices.")
        }
        try await ssh.waitForSSH()
        let script = """
        mkdir -p \(shellQuote(childRunDir)) \(shellQuote(childLogDir))
        export PATH=\(shellQuote(defaultPath)):$PATH
        if [ -e \(shellQuote("\(guestRuntimeRoot)/current")) ] && command -v llama-server >/dev/null 2>&1 && command -v rpc-server >/dev/null 2>&1; then
          true
        else
          echo 'Linux llama runtime is not installed. Start or repair the VM so guest sync can reconcile bundled runtimes, or use Core Runtimes to install a matched release pair.' >&2
          exit 127
        fi
        """
        _ = try await runGuestScript(script, timeout: 30 * 60)
    }

    public func installRuntime(spec: LlmsRuntimeInstallSpec) async throws -> LlmsRuntimeInstallResult {
        guard machine.currentPid() != nil else {
            throw RuntimeError.message("PEGPU runtime is not running. Start the runtime before installing a Linux llama runtime.")
        }
        guard spec.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "linux" else {
            throw RuntimeError.message("Only Linux llama runtime archives install into the VM.")
        }
        try await ssh.waitForSSH()

        let sourceURL = URL(fileURLWithPath: spec.sourceDir).resolvingSymlinksInPath()
        let serverURL = URL(fileURLWithPath: spec.serverPath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw RuntimeError.message("Linux llama runtime source directory is missing: \(spec.sourceDir)")
        }
        guard FileManager.default.fileExists(atPath: serverURL.path) else {
            throw RuntimeError.message("Linux llama-server is missing: \(spec.serverPath)")
        }
        let serverRel = try relativeChildPath(serverURL.path, under: sourceURL.path)
        let rpcRel: String?
        if let rpcPath = spec.rpcPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rpcPath.isEmpty {
            let rpcURL = URL(fileURLWithPath: rpcPath).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: rpcURL.path) else {
                throw RuntimeError.message("Linux rpc-server is missing: \(rpcPath)")
            }
            rpcRel = try relativeChildPath(rpcURL.path, under: sourceURL.path)
        } else {
            rpcRel = nil
        }

        let id = safeName(spec.id)
        let marker = LlmsGuestRuntimeMarker(
            id: id,
            family: spec.family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            releaseTag: spec.releaseTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            backend: spec.linuxBackend?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            archiveName: spec.assetName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            sha256: spec.sha256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            serverRel: serverRel,
            rpcRel: rpcRel,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            active: true
        )
        let markerJSON = String(data: try JSON.encoder.encode(marker), encoding: .utf8) ?? "{}"
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("pegpu-llms-runtime-\(id).tar.gz")
        try? FileManager.default.removeItem(at: archive)
        _ = try await runner.runChecked("/usr/bin/tar", ["-C", sourceURL.path, "-czf", archive.path, "."], timeout: 10 * 60)
        defer { try? FileManager.default.removeItem(at: archive) }

        let remoteArchive = "/var/tmp/pegpu-llms-runtime-\(id).tar.gz"
        try await ssh.scpToGuest(localPath: archive.path, remotePath: remoteArchive)

        let root = "\(guestRuntimeRoot)/\(id)"
        let current = "\(guestRuntimeRoot)/current"
        let serverWrapper = runtimeWrapper(root: current, executableRel: serverRel)
        let rpcWrapper = runtimeWrapper(root: current, executableRel: rpcRel ?? "rpc-server")
        let rpcInstallLines: [String]
        if let rpcRel {
            rpcInstallLines = [
                "sudo -n chmod 0755 \(shellQuote("\(root)/\(rpcRel)"))",
                "sudo -n rm -f /usr/local/bin/rpc-server",
                "printf %s \(shellQuote(rpcWrapper)) | sudo -n tee /usr/local/bin/rpc-server >/dev/null",
                "sudo -n chmod 0755 /usr/local/bin/rpc-server"
            ]
        } else {
            rpcInstallLines = []
        }

        let script = ([
            "set -eu",
            "sudo -n install -d -o pegpu -g pegpu -m 0755 \(shellQuote(guestRuntimeRoot))",
            "sudo -n rm -rf \(shellQuote(root)) \(shellQuote(root + ".tmp"))",
            "sudo -n install -d -o pegpu -g pegpu -m 0755 \(shellQuote(root + ".tmp"))",
            "sudo -n -u pegpu tar -xzf \(shellQuote(remoteArchive)) -C \(shellQuote(root + ".tmp"))",
            "sudo -n chmod -R u+rwX,go+rX \(shellQuote(root + ".tmp"))",
            "sudo -n chmod 0755 \(shellQuote("\(root).tmp/\(serverRel)"))",
            "sudo -n chown -R pegpu:pegpu \(shellQuote(root + ".tmp"))",
            "sudo -n -u pegpu mv \(shellQuote(root + ".tmp")) \(shellQuote(root))",
            "printf %s \(shellQuote(markerJSON)) | sudo -n tee \(shellQuote("\(root)/.pegpu-runtime.json")) >/dev/null",
            "sudo -n chown pegpu:pegpu \(shellQuote("\(root)/.pegpu-runtime.json"))",
            "sudo -n chmod 0644 \(shellQuote("\(root)/.pegpu-runtime.json"))",
            "sudo -n -u pegpu ln -sfn \(shellQuote(root)) \(shellQuote(current))",
            "sudo -n rm -f /usr/local/bin/llama-server",
            "printf %s \(shellQuote(serverWrapper)) | sudo -n tee /usr/local/bin/llama-server >/dev/null",
            "sudo -n chmod 0755 /usr/local/bin/llama-server"
        ] + rpcInstallLines + [
            "rm -f \(shellQuote(remoteArchive))",
            "/usr/local/bin/llama-server --version >/dev/null 2>&1 || true"
        ]).joined(separator: "\n")
        _ = try await runGuestScript(script, timeout: 20 * 60)

        return LlmsRuntimeInstallResult(
            id: id,
            root: root,
            server: "/usr/local/bin/llama-server",
            rpc: rpcRel == nil ? nil : "/usr/local/bin/rpc-server",
            active: true
        )
    }

    public func runtimeInstalled(id: String) async throws -> LlmsRuntimeInstalledResult {
        guard machine.currentPid() != nil else {
            return LlmsRuntimeInstalledResult(id: safeName(id), root: "\(guestRuntimeRoot)/\(safeName(id))", installed: false, active: false, detail: "runtime is not running")
        }
        try await ssh.waitForSSH(timeout: 10)
        let safe = safeName(id)
        let root = "\(guestRuntimeRoot)/\(safe)"
        let current = "\(guestRuntimeRoot)/current"
        let script = """
        set -u
        root=\(shellQuote(root))
        current=\(shellQuote(current))
        marker="$root/.pegpu-runtime.json"
        marker_required=false
        case \(shellQuote(safe)) in managed-*) marker_required=true ;; esac
        installed=false
        active=false
        detail=missing
        family=
        release_tag=
        backend=
        archive_name=
        sha256=
        if [ -f "$marker" ]; then
          family="$(jq -r '.family // empty' "$marker" 2>/dev/null || true)"
          release_tag="$(jq -r '.releaseTag // empty' "$marker" 2>/dev/null || true)"
          backend="$(jq -r '.backend // .linuxBackend // empty' "$marker" 2>/dev/null || true)"
          archive_name="$(jq -r '.archiveName // empty' "$marker" 2>/dev/null || true)"
          sha256="$(jq -r '.sha256 // empty' "$marker" 2>/dev/null || true)"
        fi
        if [ -d "$root" ] && { [ "$marker_required" = false ] || [ -f "$marker" ]; } && find "$root" -type f -name llama-server -perm -111 -print -quit | grep -q .; then
          installed=true
          if [ -f "$marker" ]; then detail=registered; else detail=legacy-installed; fi
          root_target="$(readlink -f "$root" 2>/dev/null || true)"
          current_target="$(readlink -f "$current" 2>/dev/null || true)"
          if [ -n "$root_target" ] && [ "$root_target" = "$current_target" ] && [ -x /usr/local/bin/llama-server ]; then
            active=true
            detail=active
          fi
        fi
        printf 'installed=%s\\nactive=%s\\ndetail=%s\\nfamily=%s\\nreleaseTag=%s\\nlinuxBackend=%s\\narchiveName=%s\\nsha256=%s\\n' "$installed" "$active" "$detail" "$family" "$release_tag" "$backend" "$archive_name" "$sha256"
        """
        let out = try await runGuestScript(script, timeout: 12)
        var installed = false
        var active = false
        var detail: String?
        var family: String?
        var releaseTag: String?
        var linuxBackend: String?
        var archiveName: String?
        var sha256: String?
        for line in out.split(whereSeparator: \.isNewline).map(String.init) {
            if line == "installed=true" { installed = true }
            if line == "active=true" { active = true }
            if line.hasPrefix("detail=") { detail = String(line.dropFirst("detail=".count)) }
            if line.hasPrefix("family=") { family = emptyNil(String(line.dropFirst("family=".count))) }
            if line.hasPrefix("releaseTag=") { releaseTag = emptyNil(String(line.dropFirst("releaseTag=".count))) }
            if line.hasPrefix("linuxBackend=") { linuxBackend = emptyNil(String(line.dropFirst("linuxBackend=".count))) }
            if line.hasPrefix("archiveName=") { archiveName = emptyNil(String(line.dropFirst("archiveName=".count))) }
            if line.hasPrefix("sha256=") { sha256 = emptyNil(String(line.dropFirst("sha256=".count))) }
        }
        return LlmsRuntimeInstalledResult(id: safe, root: root, installed: installed, active: active, detail: detail, family: family, releaseTag: releaseTag, linuxBackend: linuxBackend, archiveName: archiveName, sha256: sha256)
    }

    public func deleteInstalledRuntime(id: String) async throws {
        guard machine.currentPid() != nil else {
            throw RuntimeError.message("PEGPU runtime is not running. Start the runtime before deleting a Linux VM runtime.")
        }
        try await ssh.waitForSSH()
        let safe = safeName(id)
        let root = "\(guestRuntimeRoot)/\(safe)"
        let current = "\(guestRuntimeRoot)/current"
        let script = """
        set -eu
        current_target="$(readlink -f \(shellQuote(current)) 2>/dev/null || true)"
        target="$(readlink -f \(shellQuote(root)) 2>/dev/null || true)"
        if [ -n "$target" ] && [ "$current_target" = "$target" ]; then
          echo 'cannot delete active Linux llama runtime' >&2
          exit 1
        fi
        sudo -n rm -rf \(shellQuote(root))
        """
        _ = try await runGuestScript(script, timeout: 5 * 60)
    }

    private func ensureShareForSpec(_ spec: LlmsRuntimeSpec, shareRoot: String) async throws {
        guard specUsesHostShare(spec, shareRoot: shareRoot) else { return }
        let mounted = try await share.ensureMounted(shareRoot)
        guard case .ready = mounted else {
            throw RuntimeError.message("Mac share is not ready for VM llama.cpp runtime.")
        }
    }

    private func specUsesHostShare(_ spec: LlmsRuntimeSpec, shareRoot: String) -> Bool {
        for value in (spec.modelPaths ?? []) + (spec.mountPaths ?? []) + (spec.args ?? []) where isMacPathArg(value) {
            if (try? share.mapHostPathToGuest(value, shareRoot: shareRoot)) != nil { return true }
        }
        return false
    }

    private func validateSpecPaths(_ spec: LlmsRuntimeSpec, shareRoot: String) throws {
        for value in (spec.mountPaths ?? []) + (spec.modelPaths ?? []) {
            if isMacPathArg(value) {
                _ = try share.mapHostPathToGuest(value, shareRoot: shareRoot)
            }
        }
    }

    private func runGuestScript(_ script: String, timeout: TimeInterval? = nil) async throws -> String {
        try await ssh.ssh("bash -lc \(shellQuote(script))", timeout: timeout)
    }

    private func mapArgs(_ args: [String], shareRoot: String) -> [String] {
        args.map { mapHostPathArg($0, shareRoot: shareRoot) }
    }

    private func mapHostPathArg(_ arg: String, shareRoot: String) -> String {
        guard isMacPathArg(arg), let mapped = try? share.mapHostPathToGuest(arg, shareRoot: shareRoot) else { return arg }
        return mapped
    }

    private func isMacPathArg(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "~" ||
            trimmed.hasPrefix("~/") ||
            trimmed.hasPrefix("/Users/") ||
            trimmed.hasPrefix("/Volumes/") ||
            trimmed == "/System/Volumes/Data/Users" ||
            trimmed.hasPrefix("/System/Volumes/Data/Users/")
    }

    private func ensureBindArgs(args: [String], port: Int) -> [String] {
        var out = args
        upsertArg(&out, flag: "--host", value: VMNet.guestIP)
        upsertArg(&out, flag: "--port", value: String(port))
        return out
    }

    private func upsertArg(_ args: inout [String], flag: String, value: String) {
        for index in args.indices {
            if args[index] == flag, index + 1 < args.count {
                args[index + 1] = value
                return
            }
            if args[index].hasPrefix("\(flag)=") {
                args[index] = "\(flag)=\(value)"
                return
            }
        }
        args.append(contentsOf: [flag, value])
    }

    private func normalizeEnv(_ env: [String]) -> [String] {
        env.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) else { return nil }
            let key = String(trimmed[range].dropLast())
            let value = String(trimmed[range.upperBound...])
            return "export \(key)=\(shellQuote(value))"
        }
    }

    private func stopPidScript(_ pidFile: String) -> String {
        """
        if [ -s \(shellQuote(pidFile)) ]; then
          old="$(cat \(shellQuote(pidFile)) 2>/dev/null || true)"
          if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
            kill "$old" 2>/dev/null || true
            for i in 1 2 3 4 5; do kill -0 "$old" 2>/dev/null || break; sleep 0.2; done
            kill -0 "$old" 2>/dev/null && kill -9 "$old" 2>/dev/null || true
          fi
        fi
        """
    }

    private func parseLlamaDevices(_ output: String) -> [LlamaDevice] {
        let pattern = #"^\s*([^:]+):\s*(.*?)\s*\((\d+)\s+MiB,\s+(\d+)\s+MiB free\)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let descRange = Range(match.range(at: 2), in: text),
                  let totalRange = Range(match.range(at: 3), in: text),
                  let freeRange = Range(match.range(at: 4), in: text) else {
                return nil
            }
            let name = text[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return LlamaDevice(
                name: name,
                description: text[descRange].trimmingCharacters(in: .whitespacesAndNewlines),
                backend: backendFromDeviceName(name),
                totalMiB: Int(text[totalRange]) ?? 0,
                freeMiB: Int(text[freeRange]) ?? 0,
                pciAddress: nil,
                uuid: nil
            )
        }
    }

    private struct HardwareDevice {
        var index: Int?
        var name: String
        var backend: String
        var totalMiB: Int
        var freeMiB: Int
        var pciAddress: String?
        var uuid: String?
    }

    private func queryNvidiaDevices() async throws -> [HardwareDevice] {
        let script = """
        if command -v nvidia-smi >/dev/null 2>&1; then
          nvidia-smi --query-gpu=index,uuid,name,pci.bus_id,memory.total,memory.free --format=csv,noheader,nounits 2>/dev/null || true
        fi
        """
        let out = try await runGuestScript(script, timeout: 10)
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = String(line).split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count >= 6 else { return nil }
            return HardwareDevice(
                index: Int(parts[0]),
                name: parts[2],
                backend: "CUDA",
                totalMiB: parseMiB(parts[4]),
                freeMiB: parseMiB(parts[5]),
                pciAddress: normalizePCIAddress(parts[3]),
                uuid: parts[1].isEmpty ? nil : parts[1]
            )
        }
    }

    private func queryVulkanDevices() async throws -> [HardwareDevice] {
        let script = """
        if command -v vulkaninfo >/dev/null 2>&1; then
          vulkaninfo --summary 2>/dev/null || true
        fi
        """
        let out = try await runGuestScript(script, timeout: 20)
        return parseVulkanSummary(out)
    }

    private func parseVulkanSummary(_ output: String) -> [HardwareDevice] {
        var devices: [HardwareDevice] = []
        var current: HardwareDevice?
        let gpuRegex = try? NSRegularExpression(pattern: #"^\s*GPU(\d+)\s*:"#)
        func flush() {
            if let current, !current.name.isEmpty {
                devices.append(current)
            }
            current = nil
        }
        for rawLine in output.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = gpuRegex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                flush()
                current = HardwareDevice(index: Int(line[range]), name: "", backend: "Vulkan", totalMiB: 0, freeMiB: 0, pciAddress: nil, uuid: nil)
                continue
            }
            guard current != nil else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "deviceName":
                current?.name = parts[1]
            case "deviceUUID":
                current?.uuid = parts[1].isEmpty ? nil : parts[1]
            default:
                break
            }
        }
        flush()
        return devices
    }

    private func annotateLlamaDevices(_ devices: [LlamaDevice], nvidia: [HardwareDevice], vulkan: [HardwareDevice]) -> [LlamaDevice] {
        devices.map { device in
            var next = device
            let backend = device.backend.uppercased()
            let match: HardwareDevice?
            switch backend {
            case "CUDA":
                match = hardwareMatch(for: device, candidates: nvidia)
            case "VULKAN", "VK":
                match = hardwareMatch(for: device, candidates: vulkan)
                    ?? hardwareMatch(for: device, candidates: nvidia)
            default:
                match = nil
            }
            if let match {
                next.pciAddress = match.pciAddress
                next.uuid = match.uuid
            }
            return next
        }
    }

    private func hardwareMatch(for device: LlamaDevice, candidates: [HardwareDevice]) -> HardwareDevice? {
        let profileMatches = candidates.filter {
            normalizedDeviceName($0.name) == normalizedDeviceName(device.description) &&
            ($0.totalMiB == 0 || device.totalMiB == 0 || abs($0.totalMiB - device.totalMiB) <= 512)
        }
        if profileMatches.count == 1 {
            return profileMatches[0]
        }
        return nil
    }

    private func isVMAcceleratorBackend(_ backend: String) -> Bool {
        let upper = backend.uppercased()
        return upper == "CUDA" || upper == "VULKAN" || upper == "VK" || upper == "HIP" || upper == "SYCL" || upper == "OPENCL"
    }

    private func parseMiB(_ value: String) -> Int {
        Int(value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
    }

    private func normalizePCIAddress(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        text = text.replacingOccurrences(of: "pci:", with: "")
        text = text.replacingOccurrences(of: "00000000:", with: "0000:")
        return text.isEmpty ? nil : text
    }

    private func normalizedDeviceName(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func deviceOrdinal(_ name: String) -> Int? {
        let suffix = name.drop { !$0.isNumber }
        let digits = suffix.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    private func backendFromDeviceName(_ name: String) -> String {
        let upper = name.uppercased()
        if upper.hasPrefix("CUDA") { return "CUDA" }
        if upper.hasPrefix("RPC") { return "RPC" }
        if upper.hasPrefix("MTL") || upper.hasPrefix("METAL") { return "MTL" }
        if upper.hasPrefix("VULKAN") || upper.hasPrefix("VK") { return "Vulkan" }
        if upper.hasPrefix("SYCL") { return "SYCL" }
        if upper.hasPrefix("OPENCL") { return "OpenCL" }
        if upper.hasPrefix("CPU") { return "CPU" }
        if upper.hasPrefix("BLAS") { return "BLAS" }
        return "UNKNOWN"
    }

    private func loadSpec(_ value: String?) throws -> LlmsRuntimeSpec {
        guard let value, !value.isEmpty else { throw RuntimeError.message("missing LLMS runtime JSON spec") }
        let data: Data
        if FileManager.default.fileExists(atPath: value) {
            data = try Data(contentsOf: URL(fileURLWithPath: value))
        } else {
            data = Data(value.utf8)
        }
        return try JSON.decoder.decode(LlmsRuntimeSpec.self, from: data)
    }

    private func loadInstallSpec(_ value: String?) throws -> LlmsRuntimeInstallSpec {
        guard let value, !value.isEmpty else { throw RuntimeError.message("missing LLMS runtime install JSON spec") }
        let data: Data
        if FileManager.default.fileExists(atPath: value) {
            data = try Data(contentsOf: URL(fileURLWithPath: value))
        } else {
            data = Data(value.utf8)
        }
        return try JSON.decoder.decode(LlmsRuntimeInstallSpec.self, from: data)
    }

    private func loadHFDownloadSpec(_ value: String?) throws -> LlmsHFDownloadSpec {
        guard let value, !value.isEmpty else { throw RuntimeError.message("missing Hugging Face download JSON spec") }
        let data: Data
        if FileManager.default.fileExists(atPath: value) {
            data = try Data(contentsOf: URL(fileURLWithPath: value))
        } else {
            data = Data(value.utf8)
        }
        return try JSON.decoder.decode(LlmsHFDownloadSpec.self, from: data)
    }

    private func loadModelCopySpec(_ value: String?) throws -> LlmsModelCopySpec {
        guard let value, !value.isEmpty else { throw RuntimeError.message("missing model copy JSON spec") }
        let data: Data
        if FileManager.default.fileExists(atPath: value) {
            data = try Data(contentsOf: URL(fileURLWithPath: value))
        } else {
            data = Data(value.utf8)
        }
        return try JSON.decoder.decode(LlmsModelCopySpec.self, from: data)
    }

    private func relativeChildPath(_ child: String, under parent: String) throws -> String {
        let parentURL = URL(fileURLWithPath: parent).standardizedFileURL
        let childURL = URL(fileURLWithPath: child).standardizedFileURL
        let parentPath = parentURL.path.hasSuffix("/") ? parentURL.path : parentURL.path + "/"
        guard childURL.path.hasPrefix(parentPath) else {
            throw RuntimeError.message("\(child) is outside runtime directory \(parent)")
        }
        let relative = String(childURL.path.dropFirst(parentPath.count))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains(".."),
              !relative.hasPrefix("/") else {
            throw RuntimeError.message("invalid runtime relative path: \(relative)")
        }
        return relative
    }

    private func runtimeWrapper(root: String, executableRel: String) -> String {
        let executable = "\(root)/\(executableRel)"
        let binDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        return """
        #!/bin/sh
        export LD_LIBRARY_PATH=\(shellQuote(binDir)):\(shellQuote(root)):\(shellQuote(root + "/lib")):${LD_LIBRARY_PATH:-}
        exec \(shellQuote(executable)) "$@"
        """
    }

    private func normalizedHFPath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !path.isEmpty, !path.contains("..") else {
            throw RuntimeError.message("invalid Hugging Face path: \(value)")
        }
        return path.joined(separator: "/")
    }

    private func hfResolveURL(repo: String, revision: String, path: String) -> String {
        let encodedRepo = repo.split(separator: "/").map { urlPathComponent(String($0)) }.joined(separator: "/")
        let encodedPath = path.split(separator: "/").map { urlPathComponent(String($0)) }.joined(separator: "/")
        return "https://huggingface.co/\(encodedRepo)/resolve/\(urlPathComponent(revision))/\(encodedPath)?download=true"
    }

    private func urlPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=#%+"))) ?? value
    }

    private func childId(role: String, spec: LlmsRuntimeSpec) -> String {
        safeName(spec.id ?? "\(role)-\(shortHash((try? JSON.encoder.encode(spec)) ?? Data()))")
    }

    private func safeName(_ value: String) -> String {
        let safe = value.replacingOccurrences(of: #"[^A-Za-z0-9_.-]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? "runtime-\(UUID().uuidString.prefix(8))" : safe
    }

    private func shortHash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func validPort(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65536 else { return nil }
        return value
    }

    private func readState() -> DirectRuntimeState? {
        try? JSON.read(DirectRuntimeState.self, from: directStateFile)
    }

    private func writeState(_ state: DirectRuntimeState) throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try JSON.write(state, to: directStateFile)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSON.encoder.encode(value) + Data([0x0a]), encoding: .utf8) ?? "{}\n"
    }
}

private struct LlmsGuestRuntimeMarker: Codable {
    var id: String
    var family: String
    var releaseTag: String
    var backend: String
    var archiveName: String
    var sha256: String
    var serverRel: String
    var rpcRel: String?
    var installedAt: String
    var active: Bool
}

public struct LlmsRuntimeStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var mode: String
    public var state: DirectRuntimeState?
    public var children: [String]
}

public struct DirectRuntimeState: Codable, Equatable, Sendable {
    public var mode: String
    public var shareRoot: String?
    public var updatedAt: String

    public init(mode: String, shareRoot: String? = nil, updatedAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.mode = mode
        self.shareRoot = shareRoot
        self.updatedAt = updatedAt
    }
}

private struct DeviceList: Codable {
    var devices: [LlamaDevice]
}

private struct LlmsModelCopyProgress: Codable {
    var status: String
    var current: String?
    var copiedBytes: Int64
    var totalBytes: Int64
}

private func emptyNil(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private struct OkResponse: Codable { var ok: Bool }
private struct OkModeResponse: Codable { var ok: Bool; var mode: String }
private struct StopResponse: Codable { var ok: Bool; var id: String }
