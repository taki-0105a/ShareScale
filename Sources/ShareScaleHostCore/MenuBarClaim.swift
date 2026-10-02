import Foundation
import ShareScaleProtocol

/// ShareScale.app がメニューバーを受け持っている印（`host-control/menubar-owner.json`。計画 2f-2 案 2）。
/// `{"format":1,"pid":<ShareScale.app の pid>,"at":<UNIX 秒>}`（厳密な JSON。知らないキー・型違いは読まない）。
/// ShareScale.app は、自分のメニューに「この Mac の接続先」の節を出している間（＝見る側として動いていて、「ShareScale Host のアイコンを常に表示する」がオフの間）
/// この印を書き、終了する時・その設定をオンにした時に消す。**落ちた時は印が残る**ので、Host は印の pid が今も ShareScale.app として動いている時だけ有効とみなす
/// （`HostIconPolicy`）。秘密は載せない
public struct MenuBarClaim: Equatable, Sendable {
    public static let format: Int64 = 1
    public static let fileName = "menubar-owner.json"
    public static let maxBytes = 1024
    public var pid: Int64
    public var at: Int64
    public init?(pid: Int64, at: Int64) {
        guard pid > 0, pid <= Int64(Int32.max), (0...HostMeta.maxTime).contains(at) else { return nil }
        self.pid = pid; self.at = at
    }
    public func encoded() -> Data {
        Data((JSONWriter.write(.object([("format", .integer(Self.format)), ("pid", .integer(pid)), ("at", .integer(at))])) + "\n").utf8)
    }
    public static func decode(_ data: Data) -> MenuBarClaim? {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let v = try? StrictJSON.parse(bytes), let m = v.members(), Set(m.keys) == ["format", "pid", "at"],
              case .integer(Self.format)? = m["format"], case let .integer(pid)? = m["pid"], case let .integer(at)? = m["at"] else { return nil }
        return MenuBarClaim(pid: pid, at: at)
    }
}

/// Host のメニューバーのアイコンを出すか（純粋な関数。計画 2f-2 案 2）。
/// 出さないのは、**Host 自身が健全で**（起動に成功し、host-control の `state.json` を書けている。点検 2f-2）、印があり、
/// その pid のプロセスが今も ShareScale.app（識別子 `BundleIdentifiers.app`）として動いている時だけ。
/// それ以外（Host が起動に失敗した・`state.json` を書けない＝ShareScale の節が出ない、印が無い・読めない・pid が終わった・pid が使い回されて別のアプリになった）は出す
/// （**アイコンが消えたままにならない方に倒す**）
public enum HostIconPolicy {
    /// あるプロセスの様子（`NSRunningApplication(processIdentifier:)` の写し。無ければ nil）
    public struct RunningApp: Equatable, Sendable {
        public var bundleIdentifier: String?
        public var isTerminated: Bool
        public init(bundleIdentifier: String?, isTerminated: Bool) { self.bundleIdentifier = bundleIdentifier; self.isTerminated = isTerminated }
    }

    /// - `hostHealthy`: Host が起動に成功し、`state.json` を書けている（ShareScale のメニューに「この Mac の接続先」が出せる）
    /// - `isShareScale`: その pid のプロセスが動いていて、識別子が ShareScale.app か（実物は `isShareScale(_:lookup:)` に `NSRunningApplication` を渡す）
    public static func showsIcon(claim: MenuBarClaim?, hostHealthy: Bool, isShareScale: (Int64) -> Bool) -> Bool {
        guard hostHealthy, let c = claim else { return true }
        return !isShareScale(c.pid)
    }

    /// pid が今も ShareScale.app として動いているか（`lookup` は pid のプロセスの様子。終わった pid は nil か `isTerminated`）
    public static func isShareScale(_ pid: Int64, lookup: (pid_t) -> RunningApp?) -> Bool {
        guard let p = pid_t(exactly: pid), p > 0, let app = lookup(p) else { return false }
        return !app.isTerminated && app.bundleIdentifier == BundleIdentifiers.app
    }
}
