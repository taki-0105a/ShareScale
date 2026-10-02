import Foundation

/// 画面共有（5900 番）の接続を「この Mac が受けている」ものだけ数える。
/// 以前は行のどこかに `.5900 ` があれば数えていたため、この Mac が別の Mac を見ている時（相手側が 5900）も
/// 画面共有中と誤判定し、予備の見分け方で本物のモニタの倍率を変えるおそれがあった（点検 A-1）。
public enum ScreenSharingDetector {
    public static func hasIncomingSession(netstatOutput: String) -> Bool {
        netstatOutput.split(whereSeparator: \.isNewline).contains { line in
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // Proto Recv-Q Send-Q Local Foreign State
            guard cols.count >= 6, cols[0].hasPrefix("tcp"), cols[5] == "ESTABLISHED" else { return false }
            return cols[3].hasSuffix(".5900")
        }
    }
}
