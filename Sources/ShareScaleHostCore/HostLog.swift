import Darwin
import Foundation
import ShareScaleProtocol

/// Host の記録（仕様「記録」）。
/// - ファイル（`~/Library/Logs/ShareScale/host.log`。フォルダ 700・ファイル 600）は追記だけで書き、1 MiB を超えたら 1 世代（`host.log.1`）だけ残して切り替える
/// - 1 行は 256 バイトまで。制御文字を除く（改行も除くので、1 回の書き込みは必ず 1 行）
/// - 失敗・拒否（`noteFailure`）は、同じ送り元・同じ理由を 1 分に 1 行にまとめる。最初の 1 件をすぐ書き、1 分の間に続いた件数は、
///   1 分が過ぎてから（次の同じ失敗か `flush` で）「(N more in the last minute)」の 1 行で書く
/// - `log` の応答用に、記憶の中に直近の記録を話題（倍率の維持・ペアリングごと・そのほか）付きで持つ。`recent(for:)` は
///   倍率の維持の行と、その見る側自身の行と、拒否の集計の 1 行だけを返す（送り元・ほかの見る側は含めない）
/// - 記憶の中の記録は 2 本の輪に分ける: `log` の応答が読むもの（`.engine`・`.pairing`）と、それ以外（`.general`。失敗・拒否を含む）。
///   多くの送り元からの失敗が、倍率の維持の行を押し出さないように
///
/// 可変の状態（ファイル・記憶の中の記録・まとめ中の失敗・拒否の集計）と `formatter` は `lock` の中だけで触る
public final class HostLog: @unchecked Sendable {
    public enum Topic: Equatable, Sendable {
        case engine                 // 倍率の維持（`log` の応答に含める）
        case pairing(PairingID)     // その見る側自身の出来事（その見る側の `log` の応答にだけ含める）
        case general                // 送り元を含むもの・Host 全体の出来事（ファイルとメニューだけ）
    }
    public struct Settings: Sendable {
        public var maxFileBytes = 1024 * 1024
        public var lineMaxBytes = Limits.textMaxBytes
        public var coalesceWindow: TimeInterval = 60
        public var memoryEntries = 500      // 記憶の中の記録の上限（2 本の輪のそれぞれ）
        public var maxPendingKeys = 256
        public init() {}
        public static let standard = Settings()
    }

    public let directory: URL?
    public let settings: Settings
    private let wallClock: @Sendable () -> Date
    private let now: @Sendable () -> TimeInterval   // 単調な時計の秒（まとめる窓）
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var fileStopped = false      // 切り替えにも捨てるのにも失敗した（ファイルには書かない。記憶の中の輪は続ける）
    private var fileProblem: String?
    private struct Entry { let seq: Int; let topic: Topic; let line: String }
    private var replyEntries: [Entry] = []     // `.engine`・`.pairing`（`recent(for:)` が読む）
    private var generalEntries: [Entry] = []   // `.general`
    private var nextSeq = 0
    private struct Pending { let firstAt: TimeInterval; var extra: Int; let text: String }
    private var pending: [String: Pending] = [:]
    private var pendingOrder: [String] = []
    private var failureSeconds: [Int: Int] = [:]    // 単調な時計の秒 → 失敗・拒否の件数（直近 1 分の集計）
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// - `directory`: nil なら記憶の中だけ（ファイルに書かない）
    public init(directory: URL?, settings: Settings = .standard,
                wallClock: @escaping @Sendable () -> Date = { Date() },
                now: @escaping @Sendable () -> TimeInterval = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }) {
        self.directory = directory; self.settings = settings; self.wallClock = wallClock; self.now = now
    }
    deinit { if fd >= 0 { close(fd) } }

    /// 既定の置き場所（`~/Library/Logs/ShareScale`）
    public static func standardDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ShareScale", isDirectory: true)
    }
    var fileURL: URL? { directory?.appendingPathComponent("host.log") }

    /// 記録ファイルを開けない時の理由（診断に出す）
    public var problem: String? { lock.withLock { fileProblem } }

    /// 1 行書く（ファイルと記憶の中）
    public func write(_ text: String, topic: Topic = .general) {
        lock.withLock { append(text, topic: topic) }
    }

    /// 失敗・拒否（送り元と理由）。同じ送り元・同じ理由は 1 分に 1 行にまとめる。拒否の集計に数える
    public func noteFailure(source: String, reason: String) {
        lock.withLock {
            let t = now()
            flushExpired(t)
            failureSeconds[Int(t), default: 0] += 1
            let cutoff = Int(t) - Int(settings.coalesceWindow)
            if failureSeconds.count > Int(settings.coalesceWindow) * 2 { failureSeconds = failureSeconds.filter { $0.key > cutoff } }
            let key = source + "|" + reason
            if var p = pending[key] { p.extra += 1; pending[key] = p; return }
            let text = "\(reason) from \(source)"
            append(text, topic: .general)
            pending[key] = Pending(firstAt: t, extra: 0, text: text)
            pendingOrder.append(key)
            if pendingOrder.count > settings.maxPendingKeys { emit(pendingOrder.removeFirst()) }
        }
    }

    /// 1 分が過ぎたまとめを書き出す（定期的に呼ぶ）
    public func flush() { lock.withLock { flushExpired(now()) } }

    /// `log` の応答（最大 50 行・応答全体で 16 KiB 以下に収まる大きさ）。倍率の維持の行とその見る側自身の行、拒否の集計の 1 行
    public func recent(for id: PairingID) -> [String] {
        lock.withLock {
            var lines = replyEntries.filter { $0.topic == .engine || $0.topic == .pairing(id) }.map(\.line)
            let t = Int(now())
            let n = failureSeconds.filter { $0.key > t - Int(settings.coalesceWindow) }.values.reduce(0, +)
            if n > 0 { lines.append(stamp("rejected \(n) connection\(n == 1 ? "" : "s") in the last minute")) }
            lines = Array(lines.suffix(Limits.logMaxLines))
            // 1 行は `"…",` の 3 バイトと、エスケープで増える分を見込む。応答の枠（`{"v":1,"ok":true,"lines":[]}`）の分も残す
            let budget = Limits.responseMaxBytes - 64
            while !lines.isEmpty, lines.reduce(0, { $0 + $1.utf8.count * 2 + 3 }) > budget { lines.removeFirst() }
            return lines
        }
    }

    /// 記憶の中の直近の記録（メニューの「詳しい記録」。送り元を含む。2 本の輪を書いた順に合わせる）
    public func recentAll(_ n: Int = 100) -> [String] {
        lock.withLock { (replyEntries + generalEntries).sorted { $0.seq < $1.seq }.suffix(n).map(\.line) }
    }

    // ---- ここから lock の中 ----

    private func stamp(_ text: String) -> String {
        TextRules.clip(formatter.string(from: wallClock()) + " " + text, maxBytes: settings.lineMaxBytes)
    }

    private func append(_ text: String, topic: Topic) {
        let line = stamp(text)
        let entry = Entry(seq: nextSeq, topic: topic, line: line)
        nextSeq += 1
        if case .general = topic {
            generalEntries.append(entry)
            if generalEntries.count > settings.memoryEntries { generalEntries.removeFirst(generalEntries.count - settings.memoryEntries) }
        } else {
            replyEntries.append(entry)
            if replyEntries.count > settings.memoryEntries { replyEntries.removeFirst(replyEntries.count - settings.memoryEntries) }
        }
        writeToFile(line)
    }

    private func flushExpired(_ t: TimeInterval) {
        let expired = pendingOrder.filter { k in pending[k].map { t - $0.firstAt >= settings.coalesceWindow } ?? true }
        for k in expired { emit(k) }
    }
    private func emit(_ key: String) {
        pendingOrder.removeAll { $0 == key }
        guard let p = pending.removeValue(forKey: key) else { return }
        if p.extra > 0 { append("\(p.text) (\(p.extra) more in the last minute)", topic: .general) }
    }

    private func writeToFile(_ line: String) {
        guard let url = fileURL, !fileStopped else { return }
        if fd < 0 { openFile(url) }
        guard fd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        var st = stat()
        if fstat(fd, &st) == 0, Int(st.st_size) + bytes.count > settings.maxFileBytes {
            close(fd); fd = -1
            // 1 世代だけ残す（前の .1 は置き換わる）。名前を変えられなければ、大きくなり続けないよう消してから開き直す。
            // 消すこともできなければ、ファイルへの書き込みを止める（記憶の中の輪は続ける）。理由は診断に残し、後で切り替えに成功したら消す
            if rename(url.path, url.path + ".1") == 0 {
                if fileProblem?.hasPrefix("host.log: could not rotate") == true { fileProblem = nil }
            } else {
                let e = errno
                if unlink(url.path) == 0 {
                    fileProblem = "host.log: could not rotate (\(String(cString: strerror(e)))); the log was discarded"
                } else {
                    fileStopped = true
                    fileProblem = "host.log: could not rotate or discard (\(String(cString: strerror(e)))); file logging stopped"
                    return
                }
            }
            openFile(url)
            guard fd >= 0 else { return }
        }
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 { if errno == EINTR { continue }; fileProblem = "host.log: write failed (\(String(cString: strerror(errno))))"; return }
            off += n
        }
    }

    /// フォルダを 700 で用意し（本人のもので緩ければ 700 に直す）、ファイルを追記で開く（600・リンクはたどらない・本人の通常のファイルだけ）
    private func openFile(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var dst = stat()
        guard lstat(dir.path, &dst) == 0, (dst.st_mode & S_IFMT) == S_IFDIR, dst.st_uid == geteuid() else {
            fileProblem = "log folder is not usable: \(dir.path)"; return
        }
        if dst.st_mode & 0o077 != 0 { chmod(dir.path, 0o700) }
        let f = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { fileProblem = "host.log: \(String(cString: strerror(errno)))"; return }
        var st = stat()
        guard fstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1 else {
            close(f); fileProblem = "host.log: not a regular file of this user"; return
        }
        if st.st_mode & 0o077 != 0 { fchmod(f, 0o600) }
        fd = f
        if fileProblem?.hasPrefix("host.log: could not rotate") != true { fileProblem = nil }   // 切り替えの失敗は診断に残す
    }
}
