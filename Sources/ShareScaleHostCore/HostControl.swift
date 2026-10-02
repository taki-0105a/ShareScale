import Darwin
import Foundation
import ShareScaleEngine
import ShareScaleNet
import ShareScaleProtocol

// 同じ Mac の中の受け渡し（仕様「同じ Mac の中の受け渡し（ShareScale.app と Host）」）。
// フォルダ `~/Library/Application Support/ShareScale/host-control/`（700）に、ShareScale.app が指示 `request-<uuid>.json` を置いて
// `DistributedNotificationCenter` に「読み直して」（中身なし）を送り、Host が `at` の順に処理して消す。Host は状態を `state.json` に書く。
// 秘密・コードの文字列・proof はこの受け渡しに載せない（`issue_code` は Host 自身の窓で表示する）

/// 指示の種類（`op` の字句）
public enum HostControlOp: String, Equatable, Sendable, CaseIterable {
    case pause, resume, unpair, snooze, quit
    case issueCode = "issue_code"
    case setTailscaleOnly = "set_tailscale_only"
    case setAllowGlobal = "set_allow_global"
    /// 発行中のコードの窓をもう一度出す（ShareScale.app のメニューの「接続コードを表示…」。計画 2f-2 案 2）
    case showCode = "show_code"
    /// Host の診断の窓を出す（ShareScale.app のメニューの「この Mac の接続先」の「診断…」。計画 2f-2 案 2）
    case showDiagnostics = "show_diagnostics"
    /// 窓を出す指示か（Host が止まっていた間に置かれたものは、次の起動で急に出さない）
    public var presentsWindow: Bool { self == .issueCode || self == .showCode || self == .showDiagnostics }
    /// `id` が要るもの（`unpair`・`snooze`）
    public var needsID: Bool { self == .unpair || self == .snooze }
    /// `value` が要るもの（`set_*`）
    public var needsValue: Bool { self == .setTailscaleOnly || self == .setAllowGlobal }
}

/// 指示 1 件（`{"format":1,"op":…,"id":"<hex>"?,"value":true|false?,"at":<UNIX 秒>}`。厳密な JSON）
public struct HostControlRequest: Equatable, Sendable {
    public static let format: Int64 = 1
    public var op: HostControlOp
    public var id: PairingID?
    public var value: Bool?
    public var at: Int64
    public init?(op: HostControlOp, id: PairingID? = nil, value: Bool? = nil, at: Int64) {
        guard (id != nil) == op.needsID, (value != nil) == op.needsValue, (0...HostMeta.maxTime).contains(at) else { return nil }
        self.op = op; self.id = id; self.value = value; self.at = at
    }
    public func encoded() -> Data {
        var m: [(String, JSONValue)] = [("format", .integer(Self.format)), ("op", .string(op.rawValue))]
        if let id { m.append(("id", .string(id.hex))) }
        if let value { m.append(("value", .bool(value))) }
        m.append(("at", .integer(at)))
        return Data((JSONWriter.write(.object(m)) + "\n").utf8)
    }
    /// 厳密に読む（知らないキー・型違い・`op` に合わない `id`/`value`・範囲の外の `at` は nil）
    public static func decode(_ data: Data) -> HostControlRequest? {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let v = try? StrictJSON.parse(bytes), let m = v.members(),
              Set(m.keys).isSubset(of: ["format", "op", "id", "value", "at"]),
              case .integer(Self.format)? = m["format"], case let .string(opText)? = m["op"], let op = HostControlOp(rawValue: opText),
              case let .integer(at)? = m["at"] else { return nil }
        var id: PairingID?
        if let raw = m["id"] { guard case let .string(hex) = raw, let p = PairingID(hex: hex) else { return nil }; id = p }
        var value: Bool?
        if let raw = m["value"] { guard case let .bool(b) = raw else { return nil }; value = b }
        return HostControlRequest(op: op, id: id, value: value, at: at)
    }
}

/// Host の状態の写し（`state.json`。ShareScale.app の「この Mac の接続先」が読む）。秘密・コードの文字列・proof は載せない
public struct HostControlState: Equatable, Sendable {
    public static let format: Int64 = 1
    public struct Pairing: Equatable, Sendable {
        public var id: PairingID, name: String, lastSeen: Int64?, confirmed: Bool, stale: Bool
        public init(id: PairingID, name: String, lastSeen: Int64?, confirmed: Bool, stale: Bool) {
            self.id = id; self.name = name; self.lastSeen = lastSeen; self.confirmed = confirmed; self.stale = stale
        }
    }
    public var pid: Int64
    public var version: String        // 短い版（`CFBundleShortVersionString`。表示用）
    public var build: Int64           // `CFBundleVersion` の数（比較用。バンドルの外では 0）
    public var running: Bool
    public var paused: Bool
    public var listener: ListenerStatus
    public var pairings: [Pairing]
    public var codeExpires: Int64?
    public var host: HostDiagnostics
    public var system: SystemDiagnostics
    public var updated: Int64

    public init(pid: Int64, version: String, build: Int64, running: Bool, paused: Bool, listener: ListenerStatus, pairings: [Pairing],
                codeExpires: Int64?, host: HostDiagnostics, system: SystemDiagnostics, updated: Int64) {
        self.pid = pid; self.version = version; self.build = build; self.running = running; self.paused = paused; self.listener = listener
        self.pairings = pairings; self.codeExpires = codeExpires; self.host = host; self.system = system; self.updated = updated
    }

    /// `HostRuntime` の今の様子から
    public init(runtime r: HostRuntime, running: Bool, system: SystemDiagnostics, version: String, build: Int64, pid: Int64 = Int64(getpid()), now: Date) {
        let d = r.diagnostics
        self.init(pid: pid, version: version, build: build, running: running, paused: d.paused, listener: d.listener,
                  pairings: Self.pairings(r.pairings, stale: Set(d.staleNotices)),
                  codeExpires: r.currentCode.map { Int64($0.expires.timeIntervalSince1970) }, host: d, system: system,
                  updated: Int64(now.timeIntervalSince1970))
    }

    /// `state.json` の `pairings`（id の順。名前は制御文字を除いて `NameRules.maxBytes` に切り詰める）。
    /// メニューの元の値（`HostMenuFacts`）も同じ形で作る（両方の入口が同じ項目を返すため。計画 2f-2）
    public static func pairings(_ metas: [PairingID: HostMeta], stale: Set<PairingID>) -> [Pairing] {
        metas.sorted { $0.key.hex < $1.key.hex }.map {
            Pairing(id: $0.key, name: TextRules.clip($0.value.name, maxBytes: NameRules.maxBytes), lastSeen: $0.value.lastSeen,
                    confirmed: $0.value.confirmed, stale: stale.contains($0.key))
        }
    }

    /// 字句（`state.json` の `firewall`・`login_item`・`tailscale`）
    public static func word(_ f: FirewallStatus) -> String {
        switch f {
        case .off: return "off"; case .blockAll: return "block_all"; case .unknown: return "unknown"
        case let .on(rule):
            switch rule { case .allowed: return "allowed"; case .blocked: return "blocked"; case .notInRules: return "not_in_rules"; case .unknown: return "on" }
        }
    }
    public static func word(_ l: LoginItemStatus) -> String {
        switch l {
        case .enabled: return "enabled"; case .requiresApproval: return "requires_approval"; case .notRegistered: return "not_registered"
        case .notFound: return "not_found"; case .unknown: return "unknown"
        }
    }
    public static func word(_ t: TailscaleDetection) -> String {
        switch t { case .none: return "none"; case .ipv4Only: return "ipv4_only"; case .found: return "found" }
    }

    public func encoded() -> Data {
        func str(_ s: String?) -> JSONValue { s.map { .string(TextRules.clip($0)) } ?? .null }
        var listener: [(String, JSONValue)]
        switch self.listener {
        case .stopped: listener = [("status", .string("stopped"))]
        case .starting: listener = [("status", .string("starting"))]
        case let .listening(p): listener = [("status", .string("listening")), ("port", .integer(Int64(p)))]
        case .waitingForNetwork: listener = [("status", .string("waiting_for_network"))]
        case let .portInUse(p, r): listener = [("status", .string("port_in_use")), ("port", .integer(Int64(p))), ("retry_in", .integer(Int64(r)))]
        case let .failed(e, r): listener = [("status", .string("failed")), ("detail", str(e)), ("retry_in", .integer(Int64(r)))]
        }
        // Tailscale の IPv4 は、IPv4 と IPv6 の両方がある時だけ載せる（ShareScale.app のメニューの受け付けの行を Host のメニューと同じにするため。計画 2f-2）
        var tailscale: [(String, JSONValue)] = [("tailscale", .string(Self.word(host.tailscale)))]
        if case let .found(_, v4, _) = host.tailscale { tailscale.append(("tailscale_ipv4", .string(v4.text))) }
        let diagnostics: [(String, JSONValue)] = [
            ("tailscale_only", .bool(host.tailscaleOnly)), ("allow_global", .bool(host.allowGlobal))] + tailscale + [
            ("updating", .bool(host.updating)), ("contention", .bool(host.contention)),
            ("last_error", str(host.lastError)), ("store_problems", .integer(Int64(host.storeProblems.count))),
            ("engine_problem", str(host.engineProblem)), ("log_problem", str(host.logProblem)),
            ("rejected_global_24h", .integer(Int64(host.rejectedGlobalLast24h))), ("pairing_count", .integer(Int64(host.pairingCount))),
            ("firewall", .string(Self.word(system.firewall))), ("filevault", system.fileVault.map { .bool($0) } ?? .null),
            ("login_item", .string(Self.word(system.loginItem))),
        ]
        var m: [(String, JSONValue)] = [
            ("format", .integer(Self.format)), ("pid", .integer(pid)), ("version", .string(version)), ("build", .integer(build)),
            ("running", .bool(running)), ("paused", .bool(paused)), ("listener", .object(listener)),
            ("pairings", .array(pairings.map { p in
                .object([("id", .string(p.id.hex)), ("name", .string(p.name)), ("last_seen", p.lastSeen.map { .integer($0) } ?? .null),
                         ("confirmed", .bool(p.confirmed)), ("stale", .bool(p.stale))])
            })),
        ]
        if let x = codeExpires { m.append(("code", .object([("expires", .integer(x))]))) }
        m.append(("diagnostics", .object(diagnostics)))
        m.append(("updated", .integer(updated)))
        return Data((JSONWriter.write(.object(m)) + "\n").utf8)
    }

    /// 読む側（ShareScale.app・試験）が使う読み取り
    public struct Summary: Equatable, Sendable {
        public var pid: Int64, version: String, build: Int64, running: Bool, paused: Bool, updated: Int64
        public var listenerStatus: String, port: Int64?
        public var pairings: [Pairing]
        public var codeExpires: Int64?
        public var tailscaleOnly: Bool, allowGlobal: Bool, updating: Bool
        public var firewall: String, loginItem: String, fileVault: Bool?, lastError: String?
        /// 「この Mac の接続先」の案内に使う（奪い合い・読めないペアリングのファイルの数。計画 2d-2）
        public var contention: Bool, storeProblems: Int64
        /// ShareScale.app のメニューに Host のメニューと同じ項目を出すために読む（計画 2f-2 案 2。`HostMenuFacts(summary:)`）。
        /// 無い時（古い Host）は既定値
        public var tailscale = "none"
        public var tailscaleIPv4: String?
        public var listenerDetail: String?
        public var retryIn: Int64?
        public var engineProblem: String?
        public var logProblem: String?
        public var rejectedGlobal24h: Int64 = 0
        public var pairingCount: Int64 = 0
    }
    public static func decode(_ data: Data) -> Summary? {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let v = try? StrictJSON.parse(bytes), let m = v.members(), case .integer(Self.format)? = m["format"],
              case let .integer(pid)? = m["pid"], case let .string(version)? = m["version"], case let .integer(build)? = m["build"],
              case let .bool(running)? = m["running"], case let .bool(paused)? = m["paused"], case let .integer(updated)? = m["updated"],
              let listener = m["listener"]?.members(), case let .string(status)? = listener["status"],
              case let .array(items)? = m["pairings"], let d = m["diagnostics"]?.members(),
              case let .bool(tailscaleOnly)? = d["tailscale_only"], case let .bool(allowGlobal)? = d["allow_global"],
              case let .bool(updating)? = d["updating"], case let .string(firewall)? = d["firewall"], case let .string(loginItem)? = d["login_item"],
              case let .bool(contention)? = d["contention"],
              case let .integer(storeProblems)? = d["store_problems"]
        else { return nil }
        var port: Int64?
        if case let .integer(p)? = listener["port"] { port = p }
        var pairings: [Pairing] = []
        for item in items {
            guard let p = item.members(), case let .string(hex)? = p["id"], let id = PairingID(hex: hex), case let .string(name)? = p["name"],
                  case let .bool(confirmed)? = p["confirmed"], case let .bool(stale)? = p["stale"] else { return nil }
            var last: Int64?
            if case let .integer(l)? = p["last_seen"] { last = l }
            pairings.append(Pairing(id: id, name: name, lastSeen: last, confirmed: confirmed, stale: stale))
        }
        var code: Int64?
        if let c = m["code"]?.members(), case let .integer(x)? = c["expires"] { code = x }
        var fileVault: Bool?
        if case let .bool(b)? = d["filevault"] { fileVault = b }
        var lastError: String?
        if case let .string(e)? = d["last_error"] { lastError = e }
        var s = Summary(pid: pid, version: version, build: build, running: running, paused: paused, updated: updated, listenerStatus: status, port: port,
                        pairings: pairings, codeExpires: code, tailscaleOnly: tailscaleOnly, allowGlobal: allowGlobal, updating: updating,
                        firewall: firewall, loginItem: loginItem, fileVault: fileVault, lastError: lastError,
                        contention: contention, storeProblems: storeProblems)
        // メニューのための項目（計画 2f-2）。型が違う・無い時は既定値のまま（古い Host の `state.json` も読めるように）
        if case let .string(t)? = d["tailscale"] { s.tailscale = t }
        if case let .string(v4)? = d["tailscale_ipv4"] { s.tailscaleIPv4 = v4 }
        if case let .string(e)? = listener["detail"] { s.listenerDetail = e }
        if case let .integer(r)? = listener["retry_in"] { s.retryIn = r }
        if case let .string(e)? = d["engine_problem"] { s.engineProblem = e }
        if case let .string(e)? = d["log_problem"] { s.logProblem = e }
        if case let .integer(n)? = d["rejected_global_24h"] { s.rejectedGlobal24h = n }
        if case let .integer(n)? = d["pairing_count"] { s.pairingCount = n }
        return s
    }
}

/// `host-control/` の読み書き。読み書きは 1 つのロックで直列にする
public final class HostControlFolder: @unchecked Sendable {
    public static let notificationName = "io.github.taki-0105a.ShareScale.host-control"
    public static let maxRequestBytes = 4096
    public static let maxStateBytes = 64 * 1024
    public static let maxPerPass = 32          // 1 回の読み直しで処理する上限（残りは次の読み直しで）
    public static let maxAge: Int64 = 300      // `at` がこれより古い指示は捨てる（秒）
    public static let futureSlack: Int64 = 10  // `at` がこれより未来の指示は捨てる（秒。同じ Mac だが、書いてから読むまでのずれに少しゆとり）
    static let maxNames = 256                  // 1 回に見る指示の名前の上限
    public let directory: URL                  // …/ShareScale/host-control
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }
    /// 既定の置き場所（`~/Library/Application Support/ShareScale/host-control`）
    public static func standard() -> HostControlFolder {
        HostControlFolder(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ShareScale/host-control", isDirectory: true))
    }
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    /// `request-<uuid>.json` の名前か（uuid は小文字。ほかのファイルは触らない）
    static func requestID(_ name: String) -> String? {
        guard name.hasPrefix("request-"), name.hasSuffix(".json") else { return nil }
        let id = String(name.dropFirst(8).dropLast(5))
        guard id.count == 36, UUID(uuidString: id) != nil, id == id.lowercased() else { return nil }
        return id
    }
    var menuBarClaimURL: URL { directory.appendingPathComponent(MenuBarClaim.fileName) }

    /// 一時ファイル（`.request-<uuid>.<pid>.tmp`・`.state.<pid>.<乱数>.tmp`・`.menubar-owner.<pid>.<乱数>.tmp`）なら、名前の pid（読めなければ nil）を返す。形が違えば nil
    static func temporaryOwner(_ name: String) -> pid_t?? {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return nil }
        let parts = name.dropFirst().dropLast(4).split(separator: ".", omittingEmptySubsequences: false)
        let pidField: Substring
        if parts.count == 2, parts[0].hasPrefix("request-") { pidField = parts[1] }         // .request-<uuid>.<pid>  （uuid にドットは無い）
        else if parts.count == 3, parts[0] == "state" || parts[0] == "menubar-owner" { pidField = parts[1] }   // .state.<pid>.<乱数>・.menubar-owner.<pid>.<乱数>
        else { return nil }
        guard pidField.allSatisfy(\.isASCII), pidField.allSatisfy(\.isNumber), let pid = pid_t(pidField), pid > 0 else { return .some(nil) }
        return .some(pid)
    }

    /// フォルダ（親の `ShareScale/` も）を 700 で用意して確かめる（`ProtectedFiles`。秘密のフォルダと同じ守り方）
    func prepare() -> StoreProblem? { ProtectedFiles.prepareFolders([directory.deletingLastPathComponent(), directory]) }

    /// 書き込みの途中で落ちたプロセスの一時ファイルを消す（起動時に呼ぶ）。名前の pid が自分、または動いているプロセスのものは消さない
    public func removeStaleTemporaries() {
        lock.lock(); defer { lock.unlock() }
        guard prepare() == nil else { return }
        ProtectedFiles.removeStaleTemporaries(in: directory, owner: Self.temporaryOwner)
    }

    public struct Read: Equatable, Sendable {
        public var requests: [HostControlRequest] = []   // `at` の順（同じなら名前の順）。最大 `maxPerPass` 件
        public var dropped = 0                            // 古い・未来・読めない・形の違うもの（消した）
        public var problems: [String] = []                // 記録に残す理由
        public init() {}
    }

    /// 指示を読んで消す（受け付けたものも捨てたものも消す。上限を超えた分は残す）
    public func readRequests(now: Int64) -> Read {
        lock.lock(); defer { lock.unlock() }
        var r = Read()
        if let p = prepare() { r.problems.append("host-control folder \(p.name): \(p.reason.rawValue)"); return r }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            r.problems.append("host-control folder unreadable"); return r
        }
        var found: [(at: Int64, name: String, request: HostControlRequest?)] = []
        for name in names.filter({ Self.requestID($0) != nil }).sorted().prefix(Self.maxNames) {
            let url = directory.appendingPathComponent(name)
            switch ProtectedFiles.readFile(url, limit: Self.maxRequestBytes) {
            case let .success(d):
                if let q = HostControlRequest.decode(d) {
                    if q.at < now - Self.maxAge || q.at > now + Self.futureSlack {
                        found.append((q.at, name, nil)); r.problems.append("host-control \(name): stale or future (at \(q.at))")
                    } else { found.append((q.at, name, q)) }
                } else { found.append((0, name, nil)); r.problems.append("host-control \(name): malformed") }
            case let .failure(reason):
                found.append((0, name, nil)); r.problems.append("host-control \(name): \(reason.rawValue)")
            }
        }
        found.sort { $0.at == $1.at ? $0.name < $1.name : $0.at < $1.at }
        var taken = 0
        for f in found {
            if let q = f.request {
                guard taken < Self.maxPerPass else { continue }   // 残りは次の読み直しで（消さない）
                r.requests.append(q); taken += 1
            } else { r.dropped += 1 }
            unlink(directory.appendingPathComponent(f.name).path)
        }
        return r
    }

    /// 指示を置く（ShareScale.app 側。一時ファイル → rename、記憶装置まで書き出す）。置いた後で `postNotification()` を送る
    public func writeRequest(_ q: HostControlRequest) throws {
        lock.lock(); defer { lock.unlock() }
        if let p = prepare() { throw SecretStoreError.folder(p.reason) }
        let id = UUID().uuidString.lowercased()
        let e = ProtectedFiles.writeReplacing(directory.appendingPathComponent("request-\(id).json"), temporaryName: ".request-\(id).\(getpid()).tmp",
                                               bytes: [UInt8](q.encoded()), durable: true)
        if e != 0 { throw SecretStoreError.writeFailed(e) }
    }
    /// 状態を書く（Host 側。一時ファイル → rename。写しなので記憶装置まで書き出さない）
    public func writeState(_ s: HostControlState) throws { try writeState(encoded: s.encoded()) }
    public func writeState(encoded data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if let p = prepare() { throw SecretStoreError.folder(p.reason) }
        let e = ProtectedFiles.writeReplacing(stateURL, temporaryName: ".state.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp",
                                               bytes: [UInt8](data), durable: false)
        if e != 0 { throw SecretStoreError.writeFailed(e) }
    }
    /// 状態を読む（ShareScale.app 側・試験）。無い・読めない・形が違えば nil
    public func readState() -> HostControlState.Summary? { readStateDetailed().summary }
    /// 状態を読み、読めなかった理由も返す（`(nil, nil)` は「無い」。`problem` は読めない・形が違う理由）
    public func readStateDetailed() -> (summary: HostControlState.Summary?, problem: String?) {
        lock.lock(); defer { lock.unlock() }
        var st = stat()
        if lstat(stateURL.path, &st) != 0, errno == ENOENT { return (nil, nil) }
        switch ProtectedFiles.readFile(stateURL, limit: Self.maxStateBytes) {
        case let .failure(reason): return (nil, "state.json: \(reason.rawValue)")
        case let .success(d):
            guard let s = HostControlState.decode(d) else { return (nil, "state.json: malformed") }
            return (s, nil)
        }
    }
    /// メニューバーの受け持ちの印を書く（ShareScale.app 側。一時ファイル → rename。写しなので記憶装置まで書き出さない。計画 2f-2 案 2）
    public func writeMenuBarClaim(_ c: MenuBarClaim) throws {
        lock.lock(); defer { lock.unlock() }
        if let p = prepare() { throw SecretStoreError.folder(p.reason) }
        let e = ProtectedFiles.writeReplacing(menuBarClaimURL, temporaryName: ".menubar-owner.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp",
                                               bytes: [UInt8](c.encoded()), durable: false)
        if e != 0 { throw SecretStoreError.writeFailed(e) }
    }
    /// 印を読む（Host 側）。無い・読めない・形が違えば nil（印が無いものとして、Host はアイコンを出す）
    public func readMenuBarClaim() -> MenuBarClaim? {
        lock.lock(); defer { lock.unlock() }
        guard case let .success(d) = ProtectedFiles.readFile(menuBarClaimURL, limit: MenuBarClaim.maxBytes) else { return nil }
        return MenuBarClaim.decode(d)
    }
    /// 印を消す（ShareScale.app 側。終了する時・「ShareScale Host のアイコンを常に表示する」をオンにした時）。
    /// 印が自分の pid のものか、読めない・形が違う時だけ消す（別の ShareScale の印は消さない）
    public func removeMenuBarClaim(ownedBy pid: Int64) {
        lock.lock(); defer { lock.unlock() }
        switch ProtectedFiles.readFile(menuBarClaimURL, limit: MenuBarClaim.maxBytes) {
        case let .success(d):
            if let c = MenuBarClaim.decode(d), c.pid != pid { return }
        case .failure:
            var st = stat()
            if lstat(menuBarClaimURL.path, &st) != 0 { return }   // 無い
        }
        unlink(menuBarClaimURL.path)
    }

    /// 「読み直して」の通知（中身なし。ほかのプロセスからも送れるが、読み直しが起きるだけ）。
    /// `deliverImmediately: true` が必須（受け手が前面でない・眠っている時にも届ける）
    public static func postNotification() {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(notificationName), object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}

/// 指示を `HostRuntime` に当てた結果
public enum HostControlOutcome: Equatable, Sendable {
    case done
    case showCode(PairingCode)     // `issue_code`: Host 自身の窓で表示する（ファイルには載せない）
    case show(HostControlWindow)   // `show_code`・`show_diagnostics`: Host の窓を出す（計画 2f-2）
    case quit                      // `quit`: `HostRuntime.stop()` の後に終了する
    case failed(String)
}

/// host-control の指示で出す Host の窓（計画 2f-2）
public enum HostControlWindow: Equatable, Sendable {
    case currentCode    // 発行中のコードの窓（「接続コード」ウインドウ）
    case diagnostics    // 診断の窓
}

/// Host 側の受け渡しの本体: 通知を受けたら（そして起動時と `pollInterval` 秒ごとに保険で）フォルダを読み、`at` の順に処理して、状態を書く。
/// - 通知は「読み直しの予約」にする（予約中なら捨て、前の読み直しから `minPollInterval` は空ける）ので、乱発されても読み直しは増えない
/// - `state.json` は中身（`updated` を除く）が前回と同じなら書かない
/// - 可変の状態（`timer`・`observer`・`pendingWrite`・`pendingPoll`・`problems`・`lastWritten` など）は `lock` で守る。処理と書き込みは自分の直列のキュー（`queue`）で行う
/// - **このキューから main を同期に待つ処理を入れない**（main がこのキューを `stop()` で同期に待つため）
public final class HostControlService: @unchecked Sendable {
    public let folder: HostControlFolder
    public let runtime: HostRuntime
    public let version: String
    public let build: Int64
    public let pollInterval: TimeInterval
    /// 作った時刻（壁時計の UNIX 秒。Host の起動時）。これより前に置かれた `quit`・`issue_code` は、Host が止まっていた間に置かれたものとして捨てる
    /// （止まっている間に押された「終了」「新しい見る側を追加」を、次の起動で急に行わないため。計画 2d-2）
    public let startedAt: Int64
    public static let stateWriteDelay: TimeInterval = 0.5   // `noteChanged` をまとめる窓
    public static let minPollInterval: TimeInterval = 0.2   // 通知による読み直しの最短の間隔
    private let wallClock: @Sendable () -> Date
    private let system: @Sendable () -> SystemDiagnostics
    private let onShowCode: @Sendable (PairingCode) -> Void
    private let onShow: @Sendable (HostControlWindow) -> Void
    private let onSetting: @Sendable (HostControlOp, Bool) -> Void
    private let onQuit: @Sendable () -> Void
    private let queue = DispatchQueue(label: "sharescale.host.control")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var pendingWrite: DispatchWorkItem?
    private var pendingPoll = false
    private var lastPollAt: TimeInterval = -1
    private var problems: [String] = []
    private var quitting = false
    private var stopped = false
    private var lastWritten: Data?      // 前回書いた `state.json`（`updated` を 0 にしたもの）。書けなかったら nil に戻す（次の読み直しで書き直す）
    private var lastWriteProblem: String?   // 前回の書き込みの失敗の文言（同じ間は 1 回だけ記録）
    private var polls = 0, writes = 0
    /// 最後に知らせた「`state.json` を書けているか」（変わった時だけ `onStateHealth` を呼ぶ）
    private var healthReported: Bool?
    private let onStateHealth: @Sendable (Bool) -> Void

    /// - `system`: 診断（ファイアウォールなど）の今の値（実行体が裏で読んだもの。試験は既定値）
    /// - `onShowCode`: `issue_code` で出したコードを窓に出す（`queue` から呼ぶ）
    /// - `onShow`: `show_code`・`show_diagnostics` で Host の窓を出す（`queue` から呼ぶ。計画 2f-2）
    /// - `onSetting`: `set_tailscale_only`・`set_allow_global` を永続化する（`queue` から呼ぶ）
    /// - `onQuit`: `quit` を受けて `HostRuntime.stop()` した後（`queue` から呼ぶ。実行体は main に移して終了する）
    /// - `onStateHealth`: `state.json` を書けている・書けなくなったが変わった時（`queue` から呼ぶ。Host のアイコンを出すかに使う。点検 2f-2）
    public init(folder: HostControlFolder, runtime: HostRuntime, version: String, build: Int64, pollInterval: TimeInterval = 30,
                wallClock: @escaping @Sendable () -> Date = { Date() },
                system: @escaping @Sendable () -> SystemDiagnostics = { SystemDiagnostics() },
                onShowCode: @escaping @Sendable (PairingCode) -> Void = { _ in },
                onShow: @escaping @Sendable (HostControlWindow) -> Void = { _ in },
                onSetting: @escaping @Sendable (HostControlOp, Bool) -> Void = { _, _ in },
                onQuit: @escaping @Sendable () -> Void = {},
                onStateHealth: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.folder = folder; self.runtime = runtime; self.version = version; self.build = build; self.pollInterval = pollInterval
        self.wallClock = wallClock; self.system = system; self.onShowCode = onShowCode; self.onShow = onShow; self.onSetting = onSetting; self.onQuit = onQuit
        self.onStateHealth = onStateHealth
        startedAt = Int64(wallClock().timeIntervalSince1970)
    }
    deinit { lock.withLock { timer?.cancel(); if let o = observer { DistributedNotificationCenter.default().removeObserver(o) } } }

    /// 残った一時ファイルを片付け、通知の受け口と定期の読み直しを始め、最初の読み直しを `queue` に積む。
    /// **1 回限り**（`stop()` の後の `start()` は何もしない。Host は終了する時にしか止めない）
    public func start() {
        let started: Bool = lock.withLock {
            guard timer == nil, !stopped else { return false }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume(); timer = t
            observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(HostControlFolder.notificationName), object: nil, queue: nil) { [weak self] _ in
                self?.requestPoll()
            }
            return true
        }
        guard started else { return }
        folder.removeStaleTemporaries()
        queue.async { [weak self] in self?.poll() }
    }
    /// 止めて、`running: false` の状態を書く（同期）。以後の読み直しは何もしない。
    /// `start()` の前に呼んでも、以後の `start()` は効かない（1 回限り）
    public func stop() {
        let t: DispatchSourceTimer? = lock.withLock {
            defer { timer = nil; observer = nil; pendingWrite?.cancel(); pendingWrite = nil; stopped = true }
            if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }
            return timer
        }
        guard let t else { return }
        t.cancel()
        queue.sync { writeState(running: false) }
    }
    public var isRunning: Bool { lock.withLock { timer != nil } }
    /// 直近の読み直しで記録に残した問題
    public var lastProblems: [String] { lock.withLock { problems } }
    /// 読み直した回数と `state.json` を書いた回数（試験用）
    public var counts: (polls: Int, writes: Int) { lock.withLock { (polls, writes) } }
    /// 直近の書き込みで `state.json` を書けている（まだ書いていない・書けなかった時は偽。点検 2f-2）
    public var stateWritten: Bool { lock.withLock { lastWritten != nil } }
    /// `state.json` を書けているか（まだ 1 回も書こうとしていなければ nil）
    public var stateHealth: Bool? { lock.withLock { healthReported } }

    /// 読み直しを予約する（通知の受け口。予約中なら捨て、前の読み直しから `minPollInterval` は空ける）
    public func requestPoll() {
        let delay: TimeInterval? = lock.withLock {
            guard timer != nil, !pendingPoll else { return nil }
            pendingPoll = true
            let elapsed = ScaleMaintainer.monotonicNow() - lastPollAt
            return max(0, Self.minPollInterval - elapsed)
        }
        guard let delay else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.pendingPoll = false }
            self.poll()
        }
    }

    /// メニューに出すものが変わった（`HostRuntime.onChange` から。0.5 秒にまとめて状態を書く。同じ中身なら書かない）
    public func noteChanged() {
        lock.withLock {
            guard timer != nil, pendingWrite == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.pendingWrite = nil }
                self.writeState(running: true)
            }
            pendingWrite = w
            queue.asyncAfter(deadline: .now() + Self.stateWriteDelay, execute: w)
        }
    }

    /// 読み直し（同期。試験は直接呼ぶ）。指示を `at` の順に当て、状態を書く。`quit` を受けたら以後の指示は処理せず、`onQuit` を呼ぶ。
    /// 止めた後（`stop`）と `quit` の後は何もしない
    public func poll() {
        let skip: Bool = lock.withLock { defer { if !quitting && !stopped { polls += 1; lastPollAt = ScaleMaintainer.monotonicNow() } }; return quitting || stopped }
        if skip { return }
        let now = Int64(wallClock().timeIntervalSince1970)
        let r = folder.readRequests(now: now)
        let previous: [String] = lock.withLock { defer { problems = r.problems }; return problems }
        if r.problems != previous { for p in r.problems { runtime.log.write(p) } }   // 同じ問題が続く間は 1 回だけ
        var quit = false
        for q in r.requests {
            if Self.placedBeforeStart(q, startedAt: startedAt) {
                runtime.log.write("host-control: \(q.op.rawValue) ignored (placed before this Host started)")
                continue
            }
            let o = Self.apply(q, to: runtime)
            switch o {
            case .done: runtime.log.write("host-control: \(q.op.rawValue)")
            case let .failed(why): runtime.log.write("host-control: \(q.op.rawValue) failed: \(why)")
            case let .showCode(c): runtime.log.write("host-control: issue_code"); onShowCode(c)
            case let .show(w): runtime.log.write("host-control: \(q.op.rawValue)"); onShow(w)
            case .quit: runtime.log.write("host-control: quit"); quit = true
            }
            if let v = q.value, o == .done { onSetting(q.op, v) }
            if quit { break }
        }
        if quit { lock.withLock { quitting = true } }
        if quit {
            runtime.stop()
            writeState(running: false)
            onQuit()
        } else {
            writeState(running: true)
        }
    }

    /// 起動より前に置かれた `quit`・窓を出す指示（`issue_code`・`show_code`・`show_diagnostics`）か
    /// （捨てる。ほかの指示は設定なので、止まっていた間のものも当てる）
    public static func placedBeforeStart(_ q: HostControlRequest, startedAt: Int64) -> Bool {
        (q.op == .quit || q.op.presentsWindow) && q.at < startedAt
    }

    /// 指示 1 件を当てる（純粋に近い。`issue_code` はコードを返し、`quit` は `.quit` を返すだけで止めない）
    public static func apply(_ q: HostControlRequest, to r: HostRuntime) -> HostControlOutcome {
        switch q.op {
        case .pause: r.setPaused(true); return .done
        case .resume: r.setPaused(false); return .done
        case .issueCode: return r.issueCode().map { .showCode($0) } ?? .failed("no code (limit reached, no candidate address, or not accepting)")
        case .unpair:
            guard let id = q.id else { return .failed("no id") }
            guard r.pairings[id] != nil else { return .failed("not paired") }
            do { try r.unpair(id); return .done } catch { return .failed("\(error)") }
        case .snooze:
            guard let id = q.id else { return .failed("no id") }
            guard r.pairings[id] != nil else { return .failed("not paired") }
            r.snoozeNotice(id); return .done
        case .setTailscaleOnly: r.setTailscaleOnly(q.value ?? false); return .done
        case .setAllowGlobal: r.setAllowGlobal(q.value ?? false); return .done
        case .showCode: return r.currentCode == nil ? .failed("no code is being shown") : .show(.currentCode)
        case .showDiagnostics: return .show(.diagnostics)
        case .quit: return .quit
        }
    }

    /// `state.json` を書く。`updated` 以外が前回と同じなら書かない
    private func writeState(running: Bool) {
        var s = HostControlState(runtime: runtime, running: running, system: system(), version: version, build: build, now: wallClock())
        let stamped = s.encoded()
        s.updated = 0
        let key = s.encoded()
        let same: Bool = lock.withLock { lastWritten == key }
        if same { return }
        do {
            try folder.writeState(encoded: stamped)
            lock.withLock { writes += 1; lastWritten = key; lastWriteProblem = nil }
        } catch {
            let why = "host-control: state not written (\(error))"
            let repeated: Bool = lock.withLock { defer { lastWritten = nil; lastWriteProblem = why }; return lastWriteProblem == why }
            if !repeated { runtime.log.write(why) }
        }
        let changed: Bool? = lock.withLock {
            let now = lastWritten != nil
            guard healthReported != now else { return nil }
            healthReported = now
            return now
        }
        if let h = changed { onStateHealth(h) }
    }
}
