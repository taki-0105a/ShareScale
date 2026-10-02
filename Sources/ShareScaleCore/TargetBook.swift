import Foundation
import ShareScaleNet
import ShareScaleProtocol

/// 見る側の付帯情報（`pairings/viewer/<id>.meta`。仕様「保管」）。厳密な JSON、4 KiB 以下:
/// `{"format":1,"name":…,"addrs":{"p":…,"a":[…]},"manual":…,"last_ok_addr":…|null,"confirmed":…}`
/// - `addrs`: Host の候補アドレスと通信口（接続コード、または照合済みの `status` の `addrs`）。`a` は 1〜8 件で `CandidateAddress.isValid`、`p` は 1〜65535
/// - `manual`: 利用者が候補を手で直した（真なら `status` の `addrs` で書き換えない）
/// - `last_ok_addr`: 前回つながった候補（次回はまずそれだけを試す）。候補に無くなれば使わない
/// - `confirmed`: 名乗りの後に `status` が 1 度通った（偽なら「未確定」として案内する）
/// - `alias`: 利用者が付けた名前（任意。計画 2f-1 案 6）。画面の名前は `alias ?? name`。`NameRules` と同じ規則（1〜64 文字・128 バイト・改行などの特殊な文字を含まない）。
///   付けていなければキーを書かない（今までのファイルと同じ形のまま）。読む時はキーが無くても・null でもよい。`format` は 1 のまま
public struct ViewerMeta: Equatable, Sendable {
    public var name: String
    public var port: Int
    public var addresses: [String]
    public var manual: Bool
    public var lastOKAddress: String?
    public var confirmed: Bool
    public var alias: String?

    /// 候補の規則（通信口の範囲・1〜8 件・各アドレスの形）か、名前（`alias`）の規則に合わなければ nil。名前は Host から来たものを制御文字を除いて 128 バイトに切り詰める
    public init?(name: String, port: Int, addresses: [String], manual: Bool = false, lastOKAddress: String? = nil, confirmed: Bool, alias: String? = nil) {
        guard Limits.portRange.contains(port), (1...Limits.maxCandidateAddresses).contains(addresses.count),
              addresses.allSatisfy(CandidateAddress.isValid) else { return nil }
        if let a = alias, NameRules.validate(a) != a { return nil }
        self.name = TextRules.clip(name, maxBytes: NameRules.maxBytes); self.port = port; self.addresses = addresses; self.manual = manual
        self.lastOKAddress = lastOKAddress.flatMap { addresses.contains($0) ? $0 : nil }
        self.confirmed = confirmed
        self.alias = alias
    }

    public func encoded() -> Data {
        var members: [(String, JSONValue)] = [
            ("format", .integer(1)), ("name", .string(name)),
            ("addrs", .object([("p", .integer(Int64(port))), ("a", .array(addresses.map { .string($0) }))])),
            ("manual", .bool(manual)), ("last_ok_addr", lastOKAddress.map { .string($0) } ?? .null), ("confirmed", .bool(confirmed)),
        ]
        if let a = alias { members.append(("alias", .string(a))) }
        return Data((JSONWriter.write(.object(members)) + "\n").utf8)
    }

    static let keys: Set<String> = ["format", "name", "addrs", "manual", "last_ok_addr", "confirmed"]

    /// 厳密に読む（知らないキー・型違い・候補の規則違反・名前の規則違反は nil）。`alias` は無くても null でもよい
    public static func decode(_ data: Data) -> ViewerMeta? {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let parsed = try? StrictJSON.parse(bytes),
              let m = parsed.exactKeys(keys) ?? parsed.exactKeys(keys.union(["alias"])),
              case .integer(1)? = m["format"], case let .string(name)? = m["name"], case let .bool(manual)? = m["manual"],
              case let .bool(confirmed)? = m["confirmed"], let ad = m["addrs"]?.exactKeys(["p", "a"]),
              case let .integer(p)? = ad["p"], let port = Int(exactly: p), case let .array(items)? = ad["a"] else { return nil }
        var addrs: [String] = []
        for i in items {
            guard case let .string(a) = i else { return nil }
            addrs.append(a)
        }
        var last: String?
        switch m["last_ok_addr"] {
        case .null?: break
        case let .string(s)?: last = s
        default: return nil
        }
        var alias: String?
        switch m["alias"] {
        case nil, .null?: break
        case let .string(s)?: alias = s
        default: return nil
        }
        return ViewerMeta(name: name, port: port, addresses: addrs, manual: manual, lastOKAddress: last, confirmed: confirmed, alias: alias)
    }
}

/// 帳簿の 1 件（秘密と付帯情報がそろった、使える接続先）
public struct TargetEntry: Equatable, Sendable {
    public let id: PairingID
    public let secret: Bytes32
    public var meta: ViewerMeta
    public init(id: PairingID, secret: Bytes32, meta: ViewerMeta) { self.id = id; self.secret = secret; self.meta = meta }
    /// 表示名（利用者が付けた名前。無ければ接続先の名前、それも空なら id の先頭 8 文字）
    public var displayName: String { meta.alias ?? hostName }
    /// 接続先（Host）から来た名前（空なら id の先頭 8 文字）
    public var hostName: String { meta.name.isEmpty ? String(id.hex.prefix(8)) : meta.name }
}

/// 接続先の帳簿（仕様「保管」の見る側）。`SecretStore(role: .viewer)` の `.key` と `.meta` を読み書きし、「選んだ接続先」を `StringStore` に持つ。
/// - `.meta` の無い `.key`・読めない `.key`/`.meta` は使わず、`problems` で診断に出す（「ペアリングし直すか権限を直してください」）
/// - `.key` の無い `.meta` は使わない（読めれば `problems` にも出さない。読めなければ `SecretStore.loadMetas` の理由で `problems` に載る）。
///   次に同じ id で保存した時に置き換わる
/// - 上限 32 件は `SecretStore.save` が数える（読めないものを含む `.key` の数。`isFull` も同じ）
/// 記憶の中の可変の状態は持たない（読み書きは `SecretStore` が道筋ごとのロックで直列にする）。
/// 付帯情報の「読んで書き換える」（`status` の書き戻し・名前の変更・候補の手直し）は `modify` で、同じプロセスの中で共有する 1 つの鍵の中で行う
/// （別々に読んで書くと、名前の変更の直後に古い写しの書き戻しが名前を消すことがあった。点検 2f-1）
public final class TargetBook: @unchecked Sendable {
    public static let selectedKey = "selectedTarget"
    public static let suite = AppIdentifiers.app
    public let store: SecretStore
    private let settings: StringStore

    public init(store: SecretStore, settings: StringStore) { self.store = store; self.settings = settings }

    /// 既定の置き場所（`~/Library/Application Support/ShareScale/pairings/viewer/`）と環境設定で作る（この Mac の識別子が読めなければ nil）
    public static func standard(settings: StringStore = UserDefaults.standard) -> TargetBook? {
        SecretStore.standard(role: .viewer).map { TargetBook(store: $0, settings: settings) }
    }

    public struct Loaded: Equatable, Sendable {
        public var entries: [TargetEntry] = []      // id の hex の順
        public var problems: [StoreProblem] = []
        public init() {}
        public func entry(_ id: PairingID) -> TargetEntry? { entries.first { $0.id == id } }
        /// 表示名の順（同じなら id の順。一覧の画面用）
        public var sortedByName: [TargetEntry] {
            entries.sorted { ($0.displayName, $0.id.hex) < ($1.displayName, $1.id.hex) }
        }
    }

    /// 使える接続先と、使えなかったものの理由
    public func load() -> Loaded {
        let keys = store.loadAll()
        let metas = store.loadMetas()
        var r = Loaded()
        r.problems = keys.problems + metas.problems
        for p in keys.pairings.sorted(by: { $0.id.hex < $1.id.hex }) {
            guard let data = metas.metas[p.id] else { r.problems.append(StoreProblem(name: p.id.hex + ".meta", reason: .unreadable)); continue }
            guard let meta = ViewerMeta.decode(data) else { r.problems.append(StoreProblem(name: p.id.hex + ".meta", reason: .badFormat)); continue }
            r.entries.append(TargetEntry(id: p.id, secret: p.secret, meta: meta))
        }
        return r
    }

    /// 新しい接続先を保存する（`.key` を書いてから `.meta`。上限に達していれば `SecretStoreError.limitReached`）。
    /// `.meta` を書けなければ `.key` を消してから投げる（`.meta` の無い `.key` を残さない）
    public func add(id: PairingID, secret: Bytes32, meta: ViewerMeta) throws {
        try store.save(StoredPairing(id: id, secret: secret))
        do { try store.saveMeta(id, meta.encoded()) } catch { try? store.delete(id); throw error }
    }

    /// 付帯情報の読み書きで共有する鍵（プロセスの中で 1 つ。帳簿を作り直しても同じ鍵）
    private static let metaLock = NSLock()

    /// 付帯情報を書き直す（秘密のファイルは書き直さない）
    public func update(_ id: PairingID, _ meta: ViewerMeta) throws {
        try Self.metaLock.withLock { try store.saveMeta(id, meta.encoded()) }
    }

    /// 帳簿を読み直してから付帯情報を書き換える（読むのと書くのを 1 つの鍵の中で行う）。`change` は読み直した帳簿を受け取り、
    /// 書く付帯情報を返す（書かないなら nil。投げればそのまま投げる）
    public func modify(_ id: PairingID, _ change: (Loaded) throws -> ViewerMeta?) throws {
        counter.withLock { modifyCalls += 1 }
        try Self.metaLock.withLock {
            if let m = try change(load()) { try store.saveMeta(id, m.encoded()) }
        }
    }

    /// `modify` を呼んだ回数（試験で、書き戻し・名前の変更・確定の書き込みが `modify` を通っていることを確かめる）
    private let counter = NSLock()
    private var modifyCalls = 0
    var modifyCount: Int { counter.withLock { modifyCalls } }

    /// 削除（`.key` を消してから `.meta`。ゴミ箱には移さない）。選んでいた接続先なら選択も消す。書き換えの途中に割り込まない（同じ鍵）
    public func remove(_ id: PairingID) throws {
        try Self.metaLock.withLock { try store.delete(id) }
        if selectedID == id { selectedID = nil }
    }

    /// 上限（32 件）に達しているか（「接続先を追加」を押せなくする）。`SecretStore.save` と同じく、読めない `.key` も数える
    /// （読めない `.key` があると `add` は上限で失敗するため）。フォルダが使えなければ達していない扱い（`add` がフォルダの理由で失敗する）
    public var isFull: Bool { (store.keyCount() ?? 0) >= Limits.maxPairings }

    /// 選んだ接続先の id（`UserDefaults` の `selectedTarget`。無い・形が違えば nil）
    public var selectedID: PairingID? {
        get { settings.string(forKey: Self.selectedKey).flatMap(PairingID.init(hex:)) }
        set { settings.set(newValue?.hex, forKey: Self.selectedKey) }
    }

    /// 使う接続先: 選んだものが帳簿にあればそれ、無ければ帳簿の 1 件目（1 件も無ければ nil）
    public func selected(in loaded: Loaded) -> TargetEntry? {
        if let id = selectedID, let e = loaded.entry(id) { return e }
        return loaded.entries.first
    }
}
