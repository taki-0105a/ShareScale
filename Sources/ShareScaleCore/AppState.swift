import Darwin
import Foundation
import ShareScaleNet
import ShareScaleProtocol

/// 引き渡しの記録（`~/Library/Application Support/ShareScale/app-state.json`。仕様「置き場所と識別子」「`~/Applications` への複製と引き渡し」）。厳密な JSON、4 KiB 以下:
/// `{"format":1,"source":"<prefix>/opt/sharescale/ShareScale.app"|null,"registered_cdhash":"<hex>"|null,"attempted_handoff":{"build":n,"cdhash":"<hex>"}|null,"registered_app_cdhash":"<hex>"?}`
/// - `source`: 複製元（Homebrew 側の版に依らない場所）。予備の手順（`--install`）で入れた複製には無い
/// - `registered_cdhash`: 最後にログイン項目を登録した時の自分の CDHash（違えば登録し直す）
/// - `attempted_handoff`: 複製が Homebrew 側へ引き渡そうとした版と CDHash（同じものへは 1 回だけ）
public struct AppState: Equatable, Sendable {
    public struct Attempt: Equatable, Sendable {
        public var build: Int
        public var cdhash: String
        public init(build: Int, cdhash: String) { self.build = build; self.cdhash = cdhash }
    }
    public var source: String?
    public var registeredCDHash: String?
    public var attemptedHandoff: Attempt?
    /// 最後に「ログイン時に ShareScale を開く」（`SMAppService.mainApp`）を登録した時の自分の CDHash（違えば登録し直す。点検 2f-2）。
    /// 登録していなければキーを書かない（今までの形のまま）
    public var registeredAppCDHash: String?
    public init(source: String? = nil, registeredCDHash: String? = nil, attemptedHandoff: Attempt? = nil, registeredAppCDHash: String? = nil) {
        self.source = source; self.registeredCDHash = registeredCDHash; self.attemptedHandoff = attemptedHandoff
        self.registeredAppCDHash = registeredAppCDHash
    }

    public static let maxBytes = 4096
    static let keys: Set<String> = ["format", "source", "registered_cdhash", "attempted_handoff"]

    public func encoded() -> Data {
        let attempt: JSONValue = attemptedHandoff.map { .object([("build", .integer(Int64($0.build))), ("cdhash", .string($0.cdhash))]) } ?? .null
        var m: [(String, JSONValue)] = [
            ("format", .integer(1)), ("source", source.map { .string($0) } ?? .null),
            ("registered_cdhash", registeredCDHash.map { .string($0) } ?? .null), ("attempted_handoff", attempt),
        ]
        if let h = registeredAppCDHash { m.append(("registered_app_cdhash", .string(h))) }
        return Data((JSONWriter.write(.object(m)) + "\n").utf8)
    }

    /// 厳密に読む（知らないキー・型違い・形の違う値は nil）。`registered_app_cdhash` は有っても無くてもよい
    public static func decode(_ data: Data) -> AppState? {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let v = try? StrictJSON.parse(bytes),
              let m = v.exactKeys(keys) ?? v.exactKeys(keys.union(["registered_app_cdhash"])),
              case .integer(1)? = m["format"] else { return nil }
        var s = AppState()
        switch m["registered_app_cdhash"] {
        case nil: break
        case let .string(h)? where isHex(h): s.registeredAppCDHash = h
        default: return nil
        }
        switch m["source"] {
        case .null?: break
        case let .string(p)? where isSourcePath(p): s.source = p
        default: return nil
        }
        switch m["registered_cdhash"] {
        case .null?: break
        case let .string(h)? where isHex(h): s.registeredCDHash = h
        default: return nil
        }
        switch m["attempted_handoff"] {
        case .null?: break
        case let a?:
            guard let o = a.exactKeys(["build", "cdhash"]), case let .integer(b)? = o["build"], let build = Int(exactly: b), (0...999_999).contains(build),
                  case let .string(h)? = o["cdhash"], isHex(h) else { return nil }
            s.attemptedHandoff = Attempt(build: build, cdhash: h)
        default: return nil
        }
        return s
    }

    /// 複製元として記録できる場所（`<prefix>/opt/sharescale/ShareScale.app` の形だけ）
    public static func isSourcePath(_ p: String) -> Bool {
        AppIdentifiers.homebrewPrefixes.contains { p == "\($0)/opt/\(AppIdentifiers.formula)/\(AppIdentifiers.bundleName)" }
    }
    static func isHex(_ s: String) -> Bool { CodeSignature.isHex(s) }
}

/// `app-state.json` の読み書き（`ProtectedFiles`: 本人・600・`O_NOFOLLOW`＋`fstat`・一時ファイル → fsync → rename）
public final class AppStateFile: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }
    public static func standard() -> AppStateFile { AppStateFile(url: AppPaths.standard().appState) }

    /// 読む。無ければ既定値（問題なし）。読めない・形が違えば既定値と理由（診断に出す）
    public func load() -> (state: AppState, problem: String?) {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> (state: AppState, problem: String?) {
        switch ProtectedFiles.readFile(url, limit: AppState.maxBytes) {
        case let .success(data):
            guard let s = AppState.decode(data) else { return (AppState(), "app-state.json: badFormat") }
            return (s, nil)
        case let .failure(reason):
            if reason == .unreadable, access(url.path, F_OK) != 0, errno == ENOENT { return (AppState(), nil) }
            return (AppState(), "app-state.json: \(reason.rawValue)")
        }
    }

    /// 書く（フォルダは 700 で用意する。durable）
    public func save(_ s: AppState) throws {
        lock.lock(); defer { lock.unlock() }
        try saveLocked(s)
    }

    private func saveLocked(_ s: AppState) throws {
        let dir = url.deletingLastPathComponent()
        if let p = ProtectedFiles.prepareFolders([dir]) { throw SecretStoreError.folder(p.reason) }
        ProtectedFiles.removeStaleTemporaries(in: dir, owner: Self.temporaryOwner)
        let e = ProtectedFiles.writeReplacing(url, temporaryName: ".app-state.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp",
                                              bytes: [UInt8](s.encoded()), durable: true)
        if e != 0 { throw SecretStoreError.writeFailed(e) }
    }

    /// 読んで書き換える（読むのと書くのを 1 つの鍵の中で行う。点検 P）。読めなければ既定値から。
    /// 権限が緩いだけ（本人の通常のファイルで、中身が正しい）なら、その `source` を引き継ぐ（書き直すと 600 に戻る）
    public func update(_ change: (inout AppState) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var s = loadLocked().state
        if s == AppState(), let loose = readLoose() { s.source = loose.source }
        change(&s)
        try saveLocked(s)
    }

    /// 権限が緩い（600 より緩い）だけのファイルを読む（リンクはたどらない。本人の通常のファイルで 1 つだけのリンク・上限以下）
    private func readLoose() -> AppState? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1, st.st_mode & 0o077 != 0,
              st.st_size <= AppState.maxBytes, let bytes = ProtectedFiles.readAll(fd, limit: AppState.maxBytes + 1), bytes.count <= AppState.maxBytes else { return nil }
        return AppState.decode(bytes)
    }

    /// 一時ファイル（`.app-state.<pid>.<乱数>.tmp`）なら名前の pid
    static func temporaryOwner(_ name: String) -> pid_t?? {
        guard name.hasPrefix(".app-state."), name.hasSuffix(".tmp") else { return nil }
        let parts = name.dropFirst(".app-state.".count).dropLast(4).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let pid = pid_t(parts[0]), pid > 0 else { return .some(nil) }
        return .some(pid)
    }
}
