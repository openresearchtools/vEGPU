import CryptoKit
import Foundation
import Darwin

public let guestShareRoot = "/mnt/pegpu-share"
public let linuxHomeExportPath = "/home/pegpu"
public let defaultLinuxHomeMountPath = "/Volumes/PEGPU/Home"

public struct NFSShareState: Codable, Equatable, Sendable {
    public var backend: String = "nfs-vmnet"
    public var hostPath: String
    public var exportPath: String
    public var guestPath: String = guestShareRoot
    public var guestHost: String = VMNet.guestIP
    public var gateway: String = VMNet.gateway
    public var generation: String = ""
}

public struct GuestMountInfo: Equatable, Sendable {
    public var target: String
    public var fstype: String
    public var source: String
    public var mounted: Bool
}

public enum ShareMountResult: Equatable, Sendable {
    case ready(share: NFSShareState, expectedSource: String, remounted: Bool)
    case busy(share: NFSShareState, expectedSource: String, detail: String)
    case unavailable(share: NFSShareState, expectedSource: String, detail: String)
}

public struct LinuxHomeShareState: Codable, Equatable, Sendable {
    public var backend: String = "nfs-vmnet"
    public var exportPath: String = linuxHomeExportPath
    public var hostPath: String
    public var guestHost: String = VMNet.guestIP
    public var gateway: String = VMNet.gateway
}

public enum HostShareMountResult: Equatable, Sendable {
    case ready(share: LinuxHomeShareState, expectedSource: String, remounted: Bool)
    case busy(share: LinuxHomeShareState, expectedSource: String, detail: String)
    case unavailable(share: LinuxHomeShareState, expectedSource: String, detail: String)
}

public struct BidirectionalShareResult: Equatable, Sendable {
    public var macToLinux: ShareMountResult
    public var linuxToMac: HostShareMountResult?
}

public final class NFSShareService: @unchecked Sendable {
    private let paths: AppPaths
    private let runner: ProcessRunner
    private let ssh: SSHClient
    private let progress: ProgressCenter
    private let lock = NSLock()

    private let exportBegin = "# BEGIN PEGPU NFS SHARE"
    private let exportEnd = "# END PEGPU NFS SHARE"
    private let configBegin = "# BEGIN PEGPU NFS CONFIG"
    private let configEnd = "# END PEGPU NFS CONFIG"
    private let autoMasterBegin = "# BEGIN PEGPU LINUX HOME AUTOFS"
    private let autoMasterEnd = "# END PEGPU LINUX HOME AUTOFS"
    private let autoMapBegin = "# BEGIN PEGPU LINUX HOME MAP"
    private let autoMapEnd = "# END PEGPU LINUX HOME MAP"

    public init(paths: AppPaths, ssh: SSHClient, runner: ProcessRunner = ProcessRunner(), progress: ProgressCenter = .shared) {
        self.paths = paths
        self.ssh = ssh
        self.runner = runner
        self.progress = progress
    }

    public func ensureMounted(_ rawRoot: String) async throws -> ShareMountResult {
        let share = try await ensureHostShare(rawRoot)
        let expected = expectedSource(share)
        progress.report(ProgressEvent(stage: "share", message: "Checking Mac share in Linux", detail: share.exportPath))
        let mounted = await waitForGuestNFSShare(share: share, mode: .fast)
        if mounted.state == "ready" {
            do {
                try await reconcileGuestNFSSharePolicy(share)
            } catch {
                let detail = String(describing: error)
                progress.report(ProgressEvent(stage: "share", message: "Mac share policy repair did not finish", detail: detail, level: .error))
                return .unavailable(share: share, expectedSource: expected, detail: detail)
            }
            return .ready(share: share, expectedSource: expected, remounted: false)
        }
        if mounted.state == "unknown" || mounted.state == "unavailable" {
            let settled = await waitForGuestNFSShare(share: share, mode: .extended)
            if settled.state == "ready" {
                do {
                    try await reconcileGuestNFSSharePolicy(share)
                } catch {
                    let detail = String(describing: error)
                    progress.report(ProgressEvent(stage: "share", message: "Mac share policy repair did not finish", detail: detail, level: .error))
                    return .unavailable(share: share, expectedSource: expected, detail: detail)
                }
                return .ready(share: share, expectedSource: expected, remounted: false)
            }
            if settled.state == "unknown" || settled.state == "unavailable" {
                return .busy(share: share, expectedSource: expected, detail: describe(settled))
            }
        }
        do {
            progress.report(ProgressEvent(stage: "share", message: "Mounting Mac share in Linux", detail: "\(expected) -> \(guestShareRoot)"))
            _ = try await ssh.agent(["mount-nfs-share", VMNet.gateway, share.exportPath, guestShareRoot, share.generation], timeout: 45)
            let verified = await waitForGuestNFSShare(share: share, mode: .extended)
            if verified.state != "ready" {
                throw RuntimeError.message("Mac share mount did not verify in Linux. Expected \(expected); saw \(describe(verified)).")
            }
            return .ready(share: share, expectedSource: expected, remounted: true)
        } catch {
            let detail = String(describing: error)
            progress.report(ProgressEvent(stage: "share", message: "Mac share mount did not finish", detail: detail, level: .error))
            return .unavailable(share: share, expectedSource: expected, detail: detail)
        }
    }

    private func reconcileGuestNFSSharePolicy(_ share: NFSShareState) async throws {
        progress.report(ProgressEvent(stage: "share", message: "Refreshing Mac share policy in Linux", detail: share.exportPath))
        _ = try await ssh.agent(["mount-nfs-share", VMNet.gateway, share.exportPath, guestShareRoot, share.generation], timeout: 45)
    }

    public func ensureBidirectional(macShareRoot: String, linuxHomeMountPath: String, linuxHomeEnabled: Bool = true) async throws -> BidirectionalShareResult {
        let macToLinux = try await ensureMounted(macShareRoot)
        guard linuxHomeEnabled else {
            return BidirectionalShareResult(macToLinux: macToLinux, linuxToMac: nil)
        }
        let linuxToMac = try await ensureLinuxHomeMounted(linuxHomeMountPath)
        return BidirectionalShareResult(macToLinux: macToLinux, linuxToMac: linuxToMac)
    }

    public func ensureLinuxHomeMounted(_ rawMountPath: String = defaultLinuxHomeMountPath) async throws -> HostShareMountResult {
        let mountPath = normalizeAbsolutePath(rawMountPath, fallback: defaultLinuxHomeMountPath)
        let share = LinuxHomeShareState(hostPath: mountPath)
        let expected = expectedLinuxHomeSource()
        progress.report(ProgressEvent(stage: "share", message: "Checking Linux home on macOS", detail: "\(expected) -> \(mountPath)"))

        do {
            _ = try await ssh.agent(["export-linux-home-nfs"], timeout: 240)
        } catch {
            let detail = String(describing: error)
            progress.report(ProgressEvent(stage: "share", message: "Linux home export needs attention", detail: detail, level: .error))
            return .unavailable(share: share, expectedSource: expected, detail: detail)
        }

        try await ensureHostAutofsForLinuxHome(source: expected, mountPath: mountPath)
        let mounted = await waitForHostLinuxHomeMount(expectedSource: expected, mountPath: mountPath, mode: .fast)
        if mounted.state == "ready" {
            return .ready(share: share, expectedSource: expected, remounted: false)
        }
        if mounted.state == "busy" || mounted.state == "unknown" {
            let settled = await waitForHostLinuxHomeMount(expectedSource: expected, mountPath: mountPath, mode: .extended)
            if settled.state == "ready" {
                return .ready(share: share, expectedSource: expected, remounted: false)
            }
            if settled.state == "busy" || settled.state == "unknown" {
                return .busy(share: share, expectedSource: expected, detail: describe(settled))
            }
        }

        do {
            progress.report(ProgressEvent(stage: "share", message: "Remounting Linux home on macOS", detail: "\(expected) -> \(mountPath)"))
            try await repairHostLinuxHomeMount(source: expected, mountPath: mountPath)
            let verified = await waitForHostLinuxHomeMount(expectedSource: expected, mountPath: mountPath, mode: .extended)
            if verified.state != "ready" {
                throw RuntimeError.message("Linux home mount did not verify on macOS. Expected \(expected); saw \(describe(verified)).")
            }
            return .ready(share: share, expectedSource: expected, remounted: true)
        } catch {
            let detail = String(describing: error)
            progress.report(ProgressEvent(stage: "share", message: "Linux home mount did not finish", detail: detail, level: .error))
            return .unavailable(share: share, expectedSource: expected, detail: detail)
        }
    }

    public func ensureHostShare(_ rawRoot: String) async throws -> NFSShareState {
        let hostPath = normalizeShareRoot(rawRoot)
        try FileManager.default.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
        let exportPath = try resolvedExportRoot(for: hostPath)
        let generation = shareGeneration(hostPath: hostPath, exportPath: exportPath)
        let share = NFSShareState(hostPath: hostPath, exportPath: exportPath, generation: generation)
        let line = try nfsExportLine(exportPath)
        if await hostNfsExportIsReady(exportLine: line) {
            try writeState(share)
            return share
        }
        let detail = hostPath == exportPath ? "\(exportPath) -> \(VMNet.guestIP)" : "\(hostPath) via \(exportPath) -> \(VMNet.guestIP)"
        progress.report(ProgressEvent(stage: "share", message: "Configuring Mac NFS share", detail: detail))
        _ = try await runner.runAdminScript(nfsSetupScript(exportLine: line), prompt: [
            "PEGPU needs your Mac password to share the selected folder",
            "with the local Linux VM over private vmnet.",
            "Only 172.29.253.100 is allowed to mount it."
        ].joined(separator: " "))
        try writeState(share)
        return share
    }

    public func mapHostPathToGuest(_ value: String, shareRoot rawRoot: String, createIfMissing: Bool = false) throws -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitHostSource = isHostSharePathSource(raw)
        guard explicitHostSource || raw.hasPrefix("/") else { return nil }
        let root = normalizeShareRoot(rawRoot)
        let hostPath = resolveAgainstShareRoot(raw, root: root)
        let exportRoot = (try? resolvedExportRoot(for: root)) ?? URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let acceptedRoots = uniquePaths([root, exportRoot])
        guard let matchedRoot = acceptedRoots.first(where: { isInside(root: $0, candidate: hostPath) }) else {
            if !explicitHostSource {
                return nil
            }
            throw RuntimeError.message("Host path is outside the configured PEGPU share root.\nshare root: \(root)\npath: \(hostPath)")
        }
        if createIfMissing, !FileManager.default.fileExists(atPath: hostPath) {
            try FileManager.default.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: hostPath) else {
            throw RuntimeError.message("Host share path does not exist under the configured PEGPU share root: \(hostPath)")
        }
        let rel = URL(fileURLWithPath: matchedRoot).standardizedFileURL.path == URL(fileURLWithPath: hostPath).standardizedFileURL.path
            ? ""
            : String(hostPath.dropFirst(matchedRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? guestShareRoot : "\(guestShareRoot)/\(rel)"
    }

    public func expectedSource(_ share: NFSShareState) -> String {
        "\(VMNet.gateway):\(share.exportPath)"
    }

    public func expectedLinuxHomeSource() -> String {
        "\(VMNet.guestIP):\(linuxHomeExportPath)"
    }

    public func guestMountInfoScript(targets: [String]) -> String {
        let quoted = (targets.isEmpty ? [guestShareRoot] : targets).map(shellQuote).joined(separator: " ")
        return """
        set -u
        for target in \(quoted); do
          line=$(awk -v target="$target" '$5 == target { for (i = 1; i <= NF; i++) if ($i == "-") { print $(i + 1) "\\t" $(i + 2); exit } }' /proc/self/mountinfo 2>/dev/null || true)
          if [ -z "$line" ]; then printf '%s\\tmissing\\t\\n' "$target"; else fstype=$(printf '%s' "$line" | cut -f1); source=$(printf '%s' "$line" | cut -f2-); printf '%s\\t%s\\t%s\\n' "$target" "$fstype" "$source"; fi
        done
        """
    }

    public func parseGuestMountInfo(_ raw: String) -> [GuestMountInfo] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            let fstype = parts[1]
            return GuestMountInfo(target: parts[0], fstype: fstype, source: parts.count > 2 ? parts[2] : "", mounted: fstype != "missing")
        }
    }

    public func isExpectedNfsMount(_ info: GuestMountInfo?, expectedSource: String) -> Bool {
        guard let info else { return false }
        return info.mounted && (info.fstype == "nfs" || info.fstype == "nfs4") && info.source == expectedSource
    }

    private func hostNfsExportIsReady(exportLine: String) async -> Bool {
        guard exportsHasManagedLine(exportLine), nfsConfHasManagedBlock() else { return false }
        return ((try? await runner.run("/sbin/nfsd", ["status"]))?.code == 0)
    }

    private func exportsHasManagedLine(_ exportLine: String) -> Bool {
        guard let text = try? String(contentsOfFile: "/etc/exports", encoding: .utf8) else { return false }
        guard let begin = text.range(of: exportBegin), let end = text.range(of: exportEnd), begin.lowerBound < end.lowerBound else { return false }
        return text[begin.lowerBound..<end.upperBound].contains(exportLine)
    }

    private func nfsConfHasManagedBlock() -> Bool {
        guard let text = try? String(contentsOfFile: "/etc/nfs.conf", encoding: .utf8) else { return false }
        guard let begin = text.range(of: configBegin), let end = text.range(of: configEnd), begin.lowerBound < end.lowerBound else { return false }
        return text[begin.lowerBound..<end.upperBound].contains("nfs.server.mount.require_resv_port = 0")
    }

    private func resolvedExportRoot(for hostPath: String) throws -> String {
        let stable = URL(fileURLWithPath: hostPath).standardizedFileURL.path
        guard !stable.contains("\n"), !stable.contains("\r") else {
            throw RuntimeError.message("Share path cannot contain line breaks")
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: stable, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeError.message("Share root must be an existing directory: \(stable)")
        }
        let resolved = URL(fileURLWithPath: stable).resolvingSymlinksInPath().standardizedFileURL.path
        guard !resolved.contains("\n"), !resolved.contains("\r") else {
            throw RuntimeError.message("Resolved NFS export path cannot contain line breaks")
        }
        var resolvedIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &resolvedIsDirectory), resolvedIsDirectory.boolValue else {
            throw RuntimeError.message("Resolved NFS export root must be an existing directory: \(resolved)")
        }
        return resolved
    }

    private func shareGeneration(hostPath: String, exportPath: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(hostPath.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(exportPath.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func uniquePaths(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let path = URL(fileURLWithPath: value).standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(path)
        }
        return out
    }

    private func nfsExportLine(_ exportPath: String) throws -> String {
        guard !exportPath.contains("\n"), !exportPath.contains("\r") else {
            throw RuntimeError.message("Share path cannot contain line breaks")
        }
        return "\(quoteExportsPath(exportPath)) -alldirs -mapall=\(getuid()):\(getgid()) \(VMNet.guestIP)"
    }

    private func quoteExportsPath(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func nfsSetupScript(exportLine: String) -> String {
        """
        set -eu
        EXPORTS=/etc/exports
        NFS_CONF=/etc/nfs.conf
        BEGIN=\(shellQuote(exportBegin))
        END=\(shellQuote(exportEnd))
        CONF_BEGIN=\(shellQuote(configBegin))
        CONF_END=\(shellQuote(configEnd))
        LINE=\(shellQuote(exportLine))
        TMP="$(mktemp /tmp/pegpu-exports.XXXXXX)"
        CANDIDATE="$(mktemp /tmp/pegpu-exports-candidate.XXXXXX)"
        BACKUP="$(mktemp /tmp/pegpu-exports-backup.XXXXXX)"
        touch "$EXPORTS"
        cp "$EXPORTS" "$BACKUP"
        awk -v begin="$BEGIN" -v end="$END" '
          $0 == begin { skip=1; next }
          $0 == end { skip=0; next }
          skip != 1 { print }
        ' "$EXPORTS" > "$TMP"
        cat "$TMP" > "$CANDIDATE"
        printf '\\n%s\\n%s\\n%s\\n' "$BEGIN" "$LINE" "$END" >> "$CANDIDATE"
        if ! /sbin/nfsd -F "$CANDIDATE" checkexports; then
          rm -f "$TMP" "$CANDIDATE" "$BACKUP"
          exit 1
        fi
        install -m 0644 "$CANDIDATE" "$EXPORTS"
        touch "$NFS_CONF"
        CONF_TMP="$(mktemp /tmp/pegpu-nfs-conf.XXXXXX)"
        awk -v begin="$CONF_BEGIN" -v end="$CONF_END" '
          $0 == begin { skip=1; next }
          $0 == end { skip=0; next }
          skip != 1 { print }
        ' "$NFS_CONF" > "$CONF_TMP"
        cat >> "$CONF_TMP" <<EOF
        $CONF_BEGIN
        nfs.server.mount.require_resv_port = 0
        $CONF_END
        EOF
        install -m 0644 "$CONF_TMP" "$NFS_CONF"
        /sbin/nfsd enable
        /sbin/nfsd update || /sbin/nfsd restart || /sbin/nfsd start
        rm -f "$TMP" "$CANDIDATE" "$BACKUP" "$CONF_TMP"
        """
    }

    private enum ProbeMode { case fast, extended }

    private func waitForGuestNFSShare(share: NFSShareState, mode: ProbeMode) async -> (state: String, fstype: String?, source: String?, detail: String?) {
        let deadline = Date().addingTimeInterval(mode == .fast ? 2 : 18)
        var delay: UInt64 = 350_000_000
        var last = (state: "unknown", fstype: Optional<String>.none, source: Optional<String>.none, detail: Optional("not checked"))
        repeat {
            last = await readGuestNFSShareStatus(share: share)
            if ["ready", "missing", "wrong", "unavailable"].contains(last.state) { return last }
            if Date() < deadline {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(2_000_000_000, delay + delay / 2)
            }
        } while Date() < deadline
        return last
    }

    private func readGuestNFSShareStatus(share: NFSShareState) async -> (state: String, fstype: String?, source: String?, detail: String?) {
        let expected = expectedSource(share)
        let script = """
        set -u
        TARGET=\(shellQuote(guestShareRoot))
        EXPECTED=\(shellQuote(expected))
        HOST=\(shellQuote(VMNet.gateway))
        read_mount_line() {
          awk -v target="$TARGET" '$5 == target {
            for (i = 1; i <= NF; i++) {
              if ($i == "-") {
                if ($(i + 1) == "nfs" || $(i + 1) == "nfs4") {
                  found = 1
                  print $(i + 1) "\\t" $(i + 2)
                  exit
                }
                if (fallback == "") {
                  fallback = $(i + 1) "\\t" $(i + 2)
                }
              }
            }
          }
          END {
            if (!found && fallback != "") {
              print fallback
            }
          }' /proc/self/mountinfo 2>/dev/null || true
        }
        line=$(read_mount_line)
        if [ -z "$line" ]; then
          printf 'missing\\t\\t\\t\\n'
          exit 0
        fi
        fstype=$(printf '%s' "$line" | cut -f1)
        source=$(printf '%s' "$line" | cut -f2-)
        if { [ "$fstype" != "nfs" ] && [ "$fstype" != "nfs4" ]; } || [ "$source" != "$EXPECTED" ]; then
          printf 'wrong\\t%s\\t%s\\t\\n' "$fstype" "$source"
          exit 0
        fi
        if command -v rpcinfo >/dev/null 2>&1; then
          if ! /usr/bin/timeout 3 rpcinfo -t "$HOST" nfs 3 >/dev/null 2>&1; then
            printf 'unavailable\\t%s\\t%s\\tNFS RPC service is not reachable at %s\\n' "$fstype" "$source" "$HOST"
            exit 0
          fi
        elif command -v nc >/dev/null 2>&1; then
          if ! /usr/bin/timeout 3 nc -z "$HOST" 2049 >/dev/null 2>&1; then
            printf 'unavailable\\t%s\\t%s\\tNFS TCP port is not reachable at %s\\n' "$fstype" "$source" "$HOST"
            exit 0
          fi
        fi
        printf 'ready\\t%s\\t%s\\t\\n' "$fstype" "$source"
        """
        let result = try? await runner.run("/usr/bin/ssh", ssh.args(command: script), timeout: 8)
        let raw = ((result?.stdout.isEmpty == false ? result?.stdout : result?.stderr) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if result?.code == 0, parts.first == "ready" {
            return ("ready", parts.count > 1 ? parts[1] : "nfs", parts.count > 2 ? parts[2] : expected, nil)
        }
        if result?.code == 0, parts.first == "missing" {
            return ("missing", nil, nil, nil)
        }
        if result?.code == 0, parts.first == "wrong" {
            return ("wrong", parts.count > 1 ? parts[1] : nil, parts.count > 2 ? parts[2] : nil, nil)
        }
        if result?.code == 0, parts.first == "unavailable" {
            return ("unavailable", parts.count > 1 ? parts[1] : nil, parts.count > 2 ? parts[2] : nil, parts.count > 3 ? parts[3] : "NFS service is not reachable")
        }
        return ("unknown", nil, nil, result?.code == 124 ? "share status check timed out" : (raw.isEmpty ? "share status check failed" : raw))
    }

    private func describe(_ status: (state: String, fstype: String?, source: String?, detail: String?)) -> String {
        if status.state == "ready" { return "ready" }
        if status.state == "missing" { return "missing mount" }
        if status.state == "wrong" { return "wrong source \(status.fstype ?? "unknown") \(status.source ?? "unknown")" }
        if status.state == "unavailable" { return status.detail ?? "NFS service is not reachable" }
        return status.detail ?? status.state
    }

    private func ensureHostAutofsForLinuxHome(source: String, mountPath: String) async throws {
        guard let autofs = autofsSpec(for: mountPath) else {
            throw RuntimeError.message("Linux home mount path must have a parent and leaf path: \(mountPath)")
        }
        let mapLine = "\(autofs.key) -fstype=nfs,rw,vers=3,tcp,nolocks,noatime,rsize=65536,wsize=65536 \(source)"
        if hostAutofsIsReady(root: autofs.root, mapLine: mapLine) {
            return
        }
        progress.report(ProgressEvent(stage: "share", message: "Configuring macOS automount for Linux home", detail: mountPath))
        _ = try await runner.runAdminScript(hostAutofsSetupScript(root: autofs.root, mapLine: mapLine), prompt: [
            "PEGPU needs your Mac password once to mount the Linux home folder",
            "over the private vmnet NFS link.",
            "Normal file access after this uses the mounted filesystem directly."
        ].joined(separator: " "))
    }

    private func hostAutofsIsReady(root: String, mapLine: String) -> Bool {
        guard FileManager.default.fileExists(atPath: root) else {
            return false
        }
        guard let master = try? String(contentsOfFile: "/etc/auto_master", encoding: .utf8),
              let map = try? String(contentsOfFile: "/etc/auto_pegpu", encoding: .utf8) else {
            return false
        }
        return master.contains(autoMasterBegin) &&
            master.contains(root) &&
            map.contains(autoMapBegin) &&
            map.contains(mapLine)
    }

    private func hostAutofsSetupScript(root: String, mapLine: String) -> String {
        """
        set -eu
        MASTER=/etc/auto_master
        MAP=/etc/auto_pegpu
        ROOT=\(shellQuote(root))
        MAP_LINE=\(shellQuote(mapLine))
        MASTER_BEGIN=\(shellQuote(autoMasterBegin))
        MASTER_END=\(shellQuote(autoMasterEnd))
        MAP_BEGIN=\(shellQuote(autoMapBegin))
        MAP_END=\(shellQuote(autoMapEnd))
        touch "$MASTER" "$MAP"
        TMP="$(mktemp /tmp/pegpu-auto-master.XXXXXX)"
        awk -v begin="$MASTER_BEGIN" -v end="$MASTER_END" '
          $0 == begin { skip=1; next }
          $0 == end { skip=0; next }
          skip != 1 { print }
        ' "$MASTER" > "$TMP"
        cat >> "$TMP" <<EOF
        $MASTER_BEGIN
        $ROOT auto_pegpu -nosuid
        $MASTER_END
        EOF
        install -m 0644 "$TMP" "$MASTER"
        rm -f "$TMP"
        mkdir -p "$ROOT"
        TMP="$(mktemp /tmp/pegpu-auto-map.XXXXXX)"
        awk -v begin="$MAP_BEGIN" -v end="$MAP_END" '
          $0 == begin { skip=1; next }
          $0 == end { skip=0; next }
          skip != 1 { print }
        ' "$MAP" > "$TMP"
        cat >> "$TMP" <<EOF
        $MAP_BEGIN
        $MAP_LINE
        $MAP_END
        EOF
        install -m 0644 "$TMP" "$MAP"
        rm -f "$TMP"
        /usr/sbin/automount -vc
        """
    }

    private func repairHostLinuxHomeMount(source: String, mountPath: String) async throws {
        let script = """
        set -eu
        TARGET=\(shellQuote(mountPath))
        EXPECTED=\(shellQuote(source))
        CURRENT="$(/sbin/mount | awk -v target="$TARGET" '$3 == target { print $1; exit }')"
        if [ -n "$CURRENT" ] && [ "$CURRENT" != "$EXPECTED" ]; then
          /sbin/umount -f "$TARGET" 2>/dev/null || /usr/sbin/diskutil unmount force "$TARGET" 2>/dev/null || true
        fi
        /usr/sbin/automount -vc
        /bin/ls -la "$TARGET"/. >/dev/null
        """
        _ = try await runner.runAdminScript(script, prompt: "PEGPU needs your Mac password to repair the Linux home NFS mount.")
    }

    private func waitForHostLinuxHomeMount(expectedSource: String, mountPath: String, mode: ProbeMode) async -> (state: String, fstype: String?, source: String?, detail: String?) {
        let deadline = Date().addingTimeInterval(mode == .fast ? 6 : 60)
        var delay: UInt64 = 350_000_000
        var last = (state: "unknown", fstype: Optional<String>.none, source: Optional<String>.none, detail: Optional("not checked"))
        repeat {
            last = await readHostLinuxHomeMountStatus(expectedSource: expectedSource, mountPath: mountPath)
            if last.state == "ready" || last.state == "wrong" { return last }
            if Date() < deadline {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(2_000_000_000, delay + delay / 2)
            }
        } while Date() < deadline
        return last
    }

    private func readHostLinuxHomeMountStatus(expectedSource: String, mountPath: String) async -> (state: String, fstype: String?, source: String?, detail: String?) {
        let script = """
        set -u
        TARGET=\(shellQuote(mountPath))
        EXPECTED=\(shellQuote(expectedSource))
        [ -d "$TARGET" ] && /bin/ls -la "$TARGET"/. >/dev/null 2>&1 || true
        LINE="$(/sbin/mount | awk -v target="$TARGET" '$3 == target { print $1 "\\t" $4; exit }')"
        if [ -z "$LINE" ]; then
          printf 'missing\\t\\t\\n'
          exit 0
        fi
        SOURCE="$(printf '%s' "$LINE" | cut -f1)"
        FSTYPE="$(printf '%s' "$LINE" | cut -f2 | tr -d '()' | cut -d, -f1)"
        if [ "$SOURCE" = "$EXPECTED" ]; then
          /usr/bin/stat "$TARGET" >/dev/null
          printf 'ready\\t%s\\t%s\\n' "$FSTYPE" "$SOURCE"
        else
          printf 'wrong\\t%s\\t%s\\n' "$FSTYPE" "$SOURCE"
        fi
        """
        let result = try? await runner.run("/bin/sh", ["-lc", script], timeout: 8)
        let raw = ((result?.stdout.isEmpty == false ? result?.stdout : result?.stderr) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if result?.code == 0 {
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let state = parts.first ?? "unknown"
            if state == "ready" {
                return ("ready", parts.count > 1 ? parts[1] : "nfs", parts.count > 2 ? parts[2] : expectedSource, nil)
            }
            if state == "missing" {
                return ("missing", nil, nil, nil)
            }
            if state == "wrong" {
                return ("wrong", parts.count > 1 ? parts[1] : nil, parts.count > 2 ? parts[2] : nil, nil)
            }
        }
        return ("unknown", nil, nil, result?.code == 124 ? "Linux home probe timed out" : (raw.isEmpty ? "Linux home probe failed" : raw))
    }

    private func autofsSpec(for mountPath: String) -> (root: String, key: String)? {
        let url = URL(fileURLWithPath: mountPath).standardizedFileURL
        let key = url.lastPathComponent
        let root = url.deletingLastPathComponent().path
        guard !root.isEmpty, root != "/", !key.isEmpty, !key.contains("/") else { return nil }
        return (root, key)
    }

    private func writeState(_ state: NFSShareState) throws {
        let url = paths.shares.appendingPathComponent("nfs/share.json")
        try JSON.write(state, to: url)
    }
}

public func isHostSharePathSource(_ value: String) -> Bool {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return false }
    if raw == "~" || raw.hasPrefix("~/") || raw.hasPrefix("./") || raw.hasPrefix("../") { return true }
    if raw.hasPrefix("/Users/") || raw.hasPrefix("/Volumes/") { return true }
    if raw == "/System/Volumes/Data/Users" || raw.hasPrefix("/System/Volumes/Data/Users/") { return true }
    return !raw.hasPrefix("/") && raw.contains("/")
}

private func resolveAgainstShareRoot(_ value: String, root: String) -> String {
    let expanded = value == "~" ? NSHomeDirectory() : (value.hasPrefix("~/") ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(value.dropFirst(2))).path : value)
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return URL(fileURLWithPath: root).appendingPathComponent(expanded).standardizedFileURL.path
}

private func isInside(root: String, candidate: String) -> Bool {
    let rootURL = URL(fileURLWithPath: root).standardizedFileURL.path
    let candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL.path
    return candidateURL == rootURL || candidateURL.hasPrefix(rootURL + "/")
}
