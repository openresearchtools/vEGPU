import Foundation

public struct HostSleepGuardStatus: Codable, Equatable, Sendable {
    public var installed: Bool
    public var active: Bool
    public var mode: String
    public var pid: Int32?
    public var method: String?
    public var detail: String?

    public init(installed: Bool, active: Bool, mode: String, pid: Int32? = nil, method: String? = nil, detail: String? = nil) {
        self.installed = installed
        self.active = active
        self.mode = mode
        self.pid = pid
        self.method = method
        self.detail = detail
    }
}

public final class HostSleepGuardService: @unchecked Sendable {
    public static let helperPath = "/usr/local/sbin/pegpu-host-sleep-guard"
    private static let helperVersion = "2026.06.05.2"

    private let runner: ProcessRunner
    private let progress: ProgressCenter

    public init(runner: ProcessRunner = ProcessRunner(), progress: ProgressCenter = .shared) {
        self.runner = runner
        self.progress = progress
    }

    public func ensureInstalled() async throws {
        if FileManager.default.isExecutableFile(atPath: Self.helperPath),
           (try? String(contentsOfFile: Self.helperPath, encoding: .utf8).contains("PEGPU_SLEEP_GUARD_HELPER_VERSION=\(Self.helperVersion)")) == true {
            let sudoStatus = try? await runner.run("/usr/bin/sudo", ["-n", Self.helperPath, "status"], timeout: 3)
            if sudoStatus?.code == 0 {
                return
            }
        }
        progress.report(ProgressEvent(stage: "sleep", message: "Installing Mac sleep guard helper"))
        _ = try await runner.runAdminScript(installScript(user: NSUserName()), prompt: [
            "PEGPU needs your Mac password once to install a narrow root-owned sleep guard helper.",
            "PCIe passthrough can wedge or panic the Mac if macOS sleeps while the runtime is active.",
            "The helper can only start, stop, and report the PEGPU sleep guard."
        ].joined(separator: " "))
    }

    public func start(pid: Int32) async throws {
        guard pid > 0 else { return }
        try await ensureInstalled()
        _ = try await runner.runChecked("/usr/bin/sudo", ["-n", Self.helperPath, "start", String(pid)], timeout: 8)
        progress.report(ProgressEvent(stage: "sleep", message: "Mac sleep guard is active", detail: "PID \(pid)", level: .success))
    }

    public func forceOn() async throws {
        try await ensureInstalled()
        _ = try await runner.runChecked("/usr/bin/sudo", ["-n", Self.helperPath, "force-on"], timeout: 8)
        progress.report(ProgressEvent(stage: "sleep", message: "Mac sleep guard forced on", level: .success))
    }

    public func stop() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.helperPath) else { return }
        _ = try await runner.runChecked("/usr/bin/sudo", ["-n", Self.helperPath, "stop"], timeout: 8)
        progress.report(ProgressEvent(stage: "sleep", message: "Mac sleep guard is off"))
    }

    public func status() async -> HostSleepGuardStatus {
        guard FileManager.default.isExecutableFile(atPath: Self.helperPath) else {
            return HostSleepGuardStatus(installed: false, active: false, mode: "not-installed", detail: "helper is not installed")
        }
        guard let result = try? await runner.run("/usr/bin/sudo", ["-n", Self.helperPath, "status"], timeout: 3),
              result.code == 0,
              let data = result.stdout.data(using: .utf8),
              let status = try? JSON.decoder.decode(HostSleepGuardStatus.self, from: data) else {
            return HostSleepGuardStatus(installed: true, active: false, mode: "unknown", detail: "helper status is unavailable")
        }
        return status
    }

    private func installScript(user: String) -> String {
        let sudoersUser = user.replacingOccurrences(of: "\\", with: "\\\\")
        return #"""
        set -eu
        HELPER=/usr/local/sbin/pegpu-host-sleep-guard
        SUDOERS=/etc/sudoers.d/90-pegpu-host-sleep-guard
        install -d -m 0755 /usr/local/sbin /etc/sudoers.d
        cat >"$HELPER" <<'EOS'
        #!/usr/bin/env bash
        set -u

        STATE_DIR="/Library/Application Support/PEGPU/SleepGuard"
        PEGPU_SLEEP_GUARD_HELPER_VERSION=\#(Self.helperVersion)
        STATUS="$STATE_DIR/status.json"
        SNAPSHOT="$STATE_DIR/pmset.snapshot"
        DISABLESLEEP_SNAPSHOT="$STATE_DIR/disablesleep.snapshot"
        WORKER_PID="$STATE_DIR/worker.pid"
        COMMAND="$STATE_DIR/command"
        LOCK_DIR="$STATE_DIR/lock.d"

        ensure_state_dir() {
          mkdir -p "$STATE_DIR"
          chmod 0755 "$STATE_DIR"
        }

        json_string() {
          local value="${1:-}"
          value="${value//\\/\\\\}"
          value="${value//\"/\\\"}"
          printf '"%s"' "$value"
        }

        write_status() {
          ensure_state_dir
          local active="$1" mode="$2" pid="${3:-}" method="${4:-}" detail="${5:-}"
          local pid_json="null"
          [ -n "$pid" ] && pid_json="$pid"
          local method_json detail_json
          method_json="$(json_string "$method")"
          detail_json="$(json_string "$detail")"
          cat >"$STATUS" <<EOF
        {"installed":true,"active":$active,"mode":"$mode","pid":$pid_json,"method":$method_json,"detail":$detail_json}
        EOF
          chmod 0644 "$STATUS"
        }

        pid_running() {
          local pid="${1:-}"
          [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
        }

        save_snapshot() {
          ensure_state_dir
          if [ ! -s "$SNAPSHOT" ]; then
            pmset -g custom >"$SNAPSHOT" 2>/dev/null || true
            chmod 0600 "$SNAPSHOT" 2>/dev/null || true
          fi
          if [ ! -s "$DISABLESLEEP_SNAPSHOT" ]; then
            pmset -g 2>/dev/null | awk '$1 == "disablesleep" { print $2; found=1 } END { if (!found) print "0" }' >"$DISABLESLEEP_SNAPSHOT" ||
              printf '0\n' >"$DISABLESLEEP_SNAPSHOT"
            chmod 0600 "$DISABLESLEEP_SNAPSHOT" 2>/dev/null || true
          fi
        }

        snapshot_value() {
          local section="$1" key="$2"
          awk -v section="$section" -v key="$key" '
            $0 == section ":" { active=1; next }
            /^[A-Za-z].*:$/ { active=0 }
            active && $1 == key { print $2; exit }
          ' "$SNAPSHOT" 2>/dev/null || true
        }

        enable_guard() {
          save_snapshot
          if pmset -a disablesleep 1 >/dev/null 2>&1; then
            printf '%s\n' disablesleep
            return 0
          fi
          pmset -a sleep 0 disksleep 0 >/dev/null 2>&1 || return 1
          printf '%s\n' sleep
        }

        restore_pmset() {
          disablesleep_value="$(cat "$DISABLESLEEP_SNAPSHOT" 2>/dev/null || printf '0\n')"
          if [ "$disablesleep_value" = "1" ]; then
            pmset -a disablesleep 1 >/dev/null 2>&1 || true
          else
            pmset -a disablesleep 0 >/dev/null 2>&1 || true
          fi
          if [ -s "$SNAPSHOT" ]; then
            for source in "Battery Power" "AC Power" "UPS Power"; do
              sleep_value="$(snapshot_value "$source" sleep)"
              disksleep_value="$(snapshot_value "$source" disksleep)"
              flag=""
              case "$source" in
                "Battery Power") flag="-b" ;;
                "AC Power") flag="-c" ;;
                "UPS Power") flag="-u" ;;
              esac
              args=()
              [ -n "$sleep_value" ] && args+=(sleep "$sleep_value")
              [ -n "$disksleep_value" ] && args+=(disksleep "$disksleep_value")
              if [ "${#args[@]}" -gt 0 ]; then
                pmset "$flag" "${args[@]}" >/dev/null 2>&1 || true
              fi
            done
          fi
          rm -f "$SNAPSHOT" "$DISABLESLEEP_SNAPSHOT"
        }

        stop_existing() {
          ensure_state_dir
          printf stop >"$COMMAND"
          local pid
          pid="$(cat "$WORKER_PID" 2>/dev/null || true)"
          if pid_running "$pid"; then
            for _ in 1 2 3 4 5; do
              pid_running "$pid" || break
              sleep 0.2
            done
          fi
          if pid_running "$pid"; then
            kill "$pid" 2>/dev/null || true
          fi
          restore_pmset
          rm -f "$WORKER_PID" "$COMMAND"
          rm -rf "$LOCK_DIR"
          write_status false off "" "" "sleep guard is off"
        }

        worker() {
          local mode="$1" target_pid="${2:-}" method
          ensure_state_dir
          mkdir "$LOCK_DIR" 2>/dev/null || exit 0
          trap 'rm -rf "$LOCK_DIR"' EXIT
          method="$(enable_guard)" || {
            write_status false error "$target_pid" "" "pmset could not disable sleep"
            exit 1
          }
          printf '%s\n' "$$" >"$WORKER_PID"
          rm -f "$COMMAND"
          write_status true "$mode" "$target_pid" "$method" "preventing Mac sleep while PEGPU runtime is active"
          while :; do
            if [ -f "$COMMAND" ] && grep -q '^stop$' "$COMMAND" 2>/dev/null; then
              break
            fi
            if [ "$mode" = pid ] && ! pid_running "$target_pid"; then
              break
            fi
            sleep 2
          done
          restore_pmset
          rm -f "$WORKER_PID" "$COMMAND"
          rm -rf "$LOCK_DIR"
          write_status false off "" "" "sleep guard is off"
        }

        status() {
          if [ -s "$STATUS" ] && grep -q '"active":true' "$STATUS" 2>/dev/null; then
            worker_pid="$(cat "$WORKER_PID" 2>/dev/null || true)"
            if ! pid_running "$worker_pid"; then
              restore_pmset
              rm -f "$WORKER_PID" "$COMMAND"
              rm -rf "$LOCK_DIR"
              write_status false off "" "" "sleep guard is off"
            fi
          fi
          if [ -s "$STATUS" ]; then
            cat "$STATUS"
          else
            printf '{"installed":true,"active":false,"mode":"off","pid":null,"method":null,"detail":"sleep guard is off"}\n'
          fi
        }

        wait_active_status() {
          local current=""
          for _ in 1 2 3 4 5; do
            current="$(status)"
            if printf '%s\n' "$current" | grep -q '"active":true'; then
              printf '%s\n' "$current"
              return 0
            fi
            sleep 0.2
          done
          printf '%s\n' "$current"
          return 1
        }

        start_guard() {
          local target_pid="${1:-}"
          if ! pid_running "$target_pid"; then
            write_status false error "$target_pid" "" "QEMU pid is not running"
            exit 2
          fi
          stop_existing >/dev/null 2>&1 || true
          nohup "$0" run pid "$target_pid" >/dev/null 2>&1 &
          wait_active_status
        }

        force_on() {
          stop_existing >/dev/null 2>&1 || true
          nohup "$0" run manual "" >/dev/null 2>&1 &
          wait_active_status
        }

        case "${1:-status}" in
          start) start_guard "${2:-}" ;;
          force-on) force_on ;;
          stop) stop_existing ;;
          run) worker "${2:-manual}" "${3:-}" ;;
          status) status ;;
          *) printf 'usage: %s start PID|force-on|stop|status\n' "$0" >&2; exit 64 ;;
        esac
        EOS
        chown root:wheel "$HELPER"
        chmod 0755 "$HELPER"
        cat >"$SUDOERS" <<'EOS'
        \#(sudoersUser) ALL=(root) NOPASSWD: /usr/local/sbin/pegpu-host-sleep-guard start *, /usr/local/sbin/pegpu-host-sleep-guard force-on, /usr/local/sbin/pegpu-host-sleep-guard stop, /usr/local/sbin/pegpu-host-sleep-guard status
        EOS
        chmod 0440 "$SUDOERS"
        visudo -cf "$SUDOERS" >/dev/null || { rm -f "$SUDOERS"; exit 1; }
        "$HELPER" status >/dev/null
        """#
    }
}
