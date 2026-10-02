import XCTest

/// ShareScale（ShareScale.app と ShareScale Host）が起こす外部コマンドの一覧を、ソースの形で縛る（計画 2i）。
/// Host は常駐するので、周期で外部コマンドを起こす処理を増やさない（前は、ほかの常駐が動いているかを確かめるために、
/// 起動時と 60 秒ごとに `launchctl list` を起こしていた。計画 2i で外した）。
/// 足す時は、ここの一覧に足す（何のために・どの頻度で起こすかを、足す所の説明に書く）。
/// ソースの形で見るので、すべての書き方を防げるわけではない（文字列を組み立てて作ったパスなど）。よくある書き方（`URL(fileURLWithPath:)`・
/// `URL(filePath:)`・`URL(string: "file://…")`・システムの場所を指す文字列・`Process.run`・`Process.init`・`launchPath`・`posix_spawn`・`NSTask`・
/// スクリプトの実行）を閉じる（点検 2i・再点検 2i）
final class ExternalCommandTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `Sources/ShareScale*` の Swift のソース（相対パスと中身）。書き出し（`ShareScaleSnapshots`）は製品に入らないので除く
    func sources() throws -> [(path: String, text: String)] {
        let base = root.appendingPathComponent("Sources")
        var out: [(String, String)] = []
        for folder in try FileManager.default.contentsOfDirectory(atPath: base.path).sorted() where folder.hasPrefix("ShareScale") && folder != "ShareScaleSnapshots" {
            let dir = base.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".swift") {
                out.append(("\(folder)/\(name)", try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)))
            }
        }
        return out
    }

    /// 型に合う所（1 つ目の括弧の中）と、それがあるファイルの一覧
    func matches(_ pattern: String, in all: [(path: String, text: String)]) throws -> [String: [String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String: Set<String>] = [:]
        for (path, text) in all {
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found[String(text[Range(m.range(at: 1), in: text)!]), default: []].insert(path)
            }
        }
        return found.mapValues { $0.sorted() }
    }

    func testOnlyTheKnownSystemToolsAreRun() throws {
        let all = try sources()
        XCTAssertGreaterThan(all.count, 80, "ソースを読めている")
        // 絶対パスで指す実行ファイル（`URL(fileURLWithPath: "/…")`・`URL(filePath: "/…")`）は、ここに挙げたものだけ
        let tools = [
            "/sbin/route": ["ShareScaleCore/NetworkHints.swift"],                                   // 見る側: 届かない時だけ（別の VPN の疑い）
            "/usr/sbin/netstat": ["ShareScaleEngine/ChildProcessDisplayProvider.swift"],            // Host: 画面共有を受けているか（倍率の判定の時）
            "/usr/sbin/system_profiler": ["ShareScaleHostCore/HostController.swift"],               // Host: 機種名（起動後に 1 回）
            "/usr/libexec/ApplicationFirewall/socketfilterfw": ["ShareScaleHostCore/SystemDiagnostics.swift"],   // Host: ファイアウォールの状態（読むだけ）
            "/usr/bin/fdesetup": ["ShareScaleHostCore/SystemDiagnostics.swift"],                    // Host: FileVault の状態（読むだけ）
        ]
        var urls = tools
        urls["/System/Applications/System Settings.app"] = ["ShareScaleHostCore/SystemSettingsLink.swift"]   // 「〜の設定を開く…」（押した時だけ）
        XCTAssertEqual(try matches(#"(?:fileURLWithPath|filePath): "(/[^"]+)""#, in: all), urls)
        // 実行ファイルの置き場所（/bin・/sbin・/usr/bin・/usr/sbin・/usr/libexec）を指す文字列は、どんな書き方でも、上の道具だけ
        XCTAssertEqual(try matches(#""(/(?:bin|sbin|usr/bin|usr/sbin|usr/libexec)/[^"]*)""#, in: all), tools)
        // 外部コマンドを起こす口は、`ChildProcess.run`（中の `Process()` は 1 か所・1 回）だけ。呼ぶ所は、ファイルごとにこの回数
        var spawns: [String: Int] = [:]
        for (path, text) in all {
            let n = text.components(separatedBy: "Process()").count - 1
            if n > 0 { spawns[path] = n }
        }
        XCTAssertEqual(spawns, ["ShareScaleEngine/ChildProcessDisplayProvider.swift": 1])
        var calls: [String: Int] = [:]
        for (path, text) in all {
            let n = text.components(separatedBy: "ChildProcess.run(").count - 1
            if n > 0 { calls[path] = n }
        }
        XCTAssertEqual(calls, ["ShareScaleCore/NetworkHints.swift": 1,                       // route
                               "ShareScaleEngine/ChildProcessDisplayProvider.swift": 3,     // Host 自身（--probe・--apply-once）と netstat
                               "ShareScaleHostCore/HostController.swift": 1,                // system_profiler
                               "ShareScaleHostCore/SystemDiagnostics.swift": 1])            // socketfilterfw・fdesetup（同じ口）
        // ほかの起こし方と、`launchctl` は、どこにも無い（言及も残さない）
        // `file://` の形の URL（`URL(string: "file:///…")` など）も、絶対パスの一覧をすり抜けるので、書かない
        let forbidden = [#"(?<!Child)Process\.run\("#, #"Process\.init"#, "launchPath", "posix_spawn", "NSTask", "NSUserScriptTask", "NSAppleScript", "OSAScript",
                         #"file://"#, "launchctl"]
        for pattern in forbidden {
            let regex = try NSRegularExpression(pattern: pattern)
            for (path, text) in all {
                XCTAssertNil(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(pattern): \(path)")
            }
        }
    }
}
