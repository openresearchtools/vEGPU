import CoreGraphics
import Foundation
import PEGPUCore

@MainActor
final class GuestDisplayResolutionService {
    private let ssh: SSHClient
    private var pending: Task<Void, Never>?
    private var lastRequested = CGSize.zero

    init(paths: AppPaths) {
        self.ssh = SSHClient(paths: paths, networkStore: NetworkStateStore(paths: paths))
    }

    func request(_ size: CGSize, desktopScale: CGFloat, force: Bool = false) {
        let width = max(640, Int(size.width.rounded(.down)))
        let height = max(480, Int(size.height.rounded(.down)))
        let next = CGSize(width: width, height: height)
        guard force || next != lastRequested else {
            return
        }
        lastRequested = next
        pending?.cancel()
        pending = Task { [ssh] in
            for delay in [UInt64(900_000_000), 1_600_000_000, 3_000_000_000, 5_000_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                _ = try? await ssh.ssh(Self.plasmaDisplayCommand(width: width, height: height), timeout: 8)
            }
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    func wakeDisplay() async {
        _ = try? await ssh.ssh(Self.wakeDisplayCommand(), timeout: 8)
    }

    private static func wakeDisplayCommand() -> String {
        let script = """
        set +e
        xfce4-screensaver-command --deactivate >/dev/null 2>&1 || true
        xset s off -dpms s noblank >/dev/null 2>&1 || true
        xset dpms force on >/dev/null 2>&1 || true
        xrandr --auto >/dev/null 2>&1 || true
        xfconf-query -c xfce4-session -p /general/LockCommand -n -t string -s "" >/dev/null 2>&1 || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/presentation-mode -n -t bool -s true >/dev/null 2>&1 || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -n -t int -s 0 >/dev/null 2>&1 || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -n -t int -s 0 >/dev/null 2>&1 || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false >/dev/null 2>&1 || true
        """
        return "sudo -n loginctl unlock-sessions >/dev/null 2>&1 || true; sudo -n systemctl restart spice-vdagentd >/dev/null 2>&1 || true; sudo -n -u pegpu env DISPLAY=:0 XAUTHORITY=/home/pegpu/.Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus timeout 4s bash -lc \(shellQuote(script))"
    }

    private static func plasmaDisplayCommand(width: Int, height: Int) -> String {
        let script = """
        set -eu
        mode='\(width)x\(height)'
        if command -v kscreen-doctor >/dev/null 2>&1; then
          output="$(kscreen-doctor -o 2>/dev/null | awk '/^Output:/ && / connected/ { print $2; exit }')"
          [ -n "$output" ] || exit 0
          mode_id="$(kscreen-doctor -o 2>/dev/null | awk -v output="$output" -v mode="$mode" '
            $1 == "Output:" && $2 == output { in_output = 1; next }
            $1 == "Output:" { in_output = 0 }
            in_output && $1 ~ /^[0-9]+:/ && $2 == mode { sub(":", "", $1); print $1; exit }
          ')"
          [ -n "$mode_id" ] || exit 0
          kscreen-doctor "output.$output.mode.$mode_id" >/dev/null 2>&1 || true
          /usr/local/bin/pegpu-plasma-apply-scale >/dev/null 2>&1 || true
          exit 0
        fi
        output="$(xrandr --query | awk '$1 == "Virtual-1" && $2 == "connected" { print $1; found = 1; exit } / connected/ && !found { fallback = $1 } END { if (!found && fallback != "") print fallback }')"
        [ -n "$output" ] || exit 0
        if ! xrandr --query | awk -v mode="$mode" '$1 == mode { found = 1 } END { exit found ? 0 : 1 }'; then
          exit 0
        fi
        current="$(xrandr --query | awk '/ connected/{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\\+[0-9]+\\+[0-9]+$/) { split($i, a, "+"); print a[1]; exit } }')"
        [ "$current" = "$mode" ] || xrandr --output "$output" --mode "$mode"
        """
        return "sudo -n -u pegpu env DISPLAY=:0 XAUTHORITY=/home/pegpu/.Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus bash -lc \(shellQuote(script))"
    }
}
