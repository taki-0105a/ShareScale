import Foundation
import ShareScaleEngine

/// 届かない時の原因の手がかり（外部コマンドは `ShareScaleEngine.ChildProcess` で起こす）
public enum NetworkHints {
    /// `route -n get default` の出力から、既定の経路がトンネル（別の VPN や exit node）を通っているか。
    /// Tailscale は exit node を使わない限り既定の経路を握らないので、ここが utun なら別の VPN の可能性が高い
    public static func defaultRouteIsTunnel(routeOutput: String) -> Bool {
        for line in routeOutput.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("interface:") else { continue }
            let iface = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp")
        }
        return false
    }

    /// 実際に既定の経路を調べる（3 秒で打ち切り）
    public static func checkDefaultRoute() -> Bool {
        defaultRouteIsTunnel(routeOutput: ChildProcess.run(URL(fileURLWithPath: "/sbin/route"), ["-n", "get", "default"], timeout: 3).output)
    }
}
