import Darwin
import Foundation
import ShareScaleNet

/// 倍率の維持の状態（`~/Library/Application Support/ShareScale/engine.json` の 1 ファイル。設定した倍率・一時停止・最後に設定した見る側と時刻 `set_by`・物理モニタの一覧・学習の候補・直近の失敗）
public struct EngineState: Equatable, Sendable {
    /// 最後に倍率を設定した見る側（ペアリング ID の hex）と時刻（UNIX 秒）。`status` の `set_by` に使う
    public struct SetRecord: Equatable, Sendable {
        public var by: String
        public var at: Int64
        public init(by: String, at: Int64) { self.by = by; self.at = at }
    }
    public var mode: ScaleMode = .x1
    public var paused = false                 // メニューの「一時停止」（倍率を変えない。起動し直しても保つ）
    public var learned: [String] = []         // 学習済みの物理モニタ（古い→新しい。`Decision.mergeLearned`）
    public var learnCandidate: LearnCandidate?
    public var lastError: String?
    public var setBy: SetRecord?
    public init() {}
}

/// engine.json の読み書き。書き込みは同じフォルダの一時ファイル（600・`O_EXCL|O_NOFOLLOW`）に書いて fsync してから名前を変える。
/// 読めない・壊れている時は既定値で動き、問題を返す（Host は止めない）
public struct EngineStateFile: Sendable {
    public let url: URL
    static let maxBytes = 64 * 1024
    static let maxLearned = 16

    public init(url: URL) { self.url = url }

    /// 既定の置き場所（`~/Library/Application Support/ShareScale/engine.json`）
    public static func standard() -> EngineStateFile {
        EngineStateFile(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ShareScale/engine.json"))
    }

    /// 読む。無ければ既定値（問題なし）。読めない・壊れていれば既定値と問題。
    /// ファイルの確かめは秘密と同じ（`ProtectedFiles.readFile`: リンクをたどらない・通常ファイル・本人・600 より緩くない・上限以下）
    public func load() -> (state: EngineState, problem: String?) {
        var st = stat()
        if lstat(url.path, &st) != 0, errno == ENOENT { return (EngineState(), nil) }   // 無ければ既定値（宙ぶらりんのリンクは「無い」ではなく問題）
        switch ProtectedFiles.readFile(url, limit: Self.maxBytes) {
        case let .success(data):
            guard let state = Self.decode(data) else { return (EngineState(), "engine.json: unreadable contents; using defaults") }
            return (state, nil)
        case let .failure(reason):
            return (EngineState(), "engine.json: \(Self.describe(reason)); using defaults")
        }
    }

    static func describe(_ r: StoreProblem.Reason) -> String {
        switch r {
        case .notRegularFile: return "not a regular file"
        case .wrongOwner, .loosePermissions: return "owner or permissions are wrong"
        case .multipleLinks: return "has more than one link"
        case .tooLarge: return "too large"
        case .unreadable, .badFormat, .roleMismatch, .idMismatch, .otherMachine,
             .folderNotDirectory, .folderWrongOwner, .folderLoosePermissions, .folderUnavailable: return "unreadable"
        }
    }

    /// 書く（フォルダが無ければ 700 で作る。あって本人のもので緩ければ 700 に直す）。
    /// 一時ファイル（600・`O_EXCL|O_NOFOLLOW`）から入れ替え、記憶装置まで書き出し、フォルダも書き出す（`ProtectedFiles.writeReplacing(durable: true)`）
    public func save(_ state: EngineState) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var dst = stat()
        if stat(dir.path, &dst) == 0, dst.st_uid == geteuid(), dst.st_mode & 0o077 != 0 { chmod(dir.path, 0o700) }
        let data = try Self.encode(state)
        let e = ProtectedFiles.writeReplacing(url, temporaryName: ".engine.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp",
                                             bytes: [UInt8](data), durable: true)
        if e != 0 { throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
    }

    // ---- 形（`{"format":1,"learned":[…],"mode":"1x","paused":false}` に、あれば `learn_candidate`・`last_error`・`set_by` を足す。無い項目は書かない）----

    private struct File: Codable {
        struct Candidate: Codable { var ids: [String]; var since: Double; var boot: Int? }
        struct SetBy: Codable { var by: String; var at: Int64 }
        var format: Int
        var mode: String
        var paused: Bool
        var learned: [String]
        var learn_candidate: Candidate?
        var last_error: String?
        var set_by: SetBy?
    }

    static func encode(_ s: EngineState) throws -> Data {
        let f = File(format: 1, mode: s.mode.rawValue, paused: s.paused, learned: Array(s.learned.suffix(maxLearned)),
                     learn_candidate: s.learnCandidate.map { File.Candidate(ids: $0.ids.sorted(), since: $0.since, boot: $0.boot) },
                     last_error: s.lastError, set_by: s.setBy.map { File.SetBy(by: $0.by, at: $0.at) })
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(f) + Data("\n".utf8)
    }

    static func decode(_ data: Data) -> EngineState? {
        guard let f = try? JSONDecoder().decode(File.self, from: data), f.format == 1, let mode = ScaleMode(rawValue: f.mode) else { return nil }
        var s = EngineState()
        s.mode = mode; s.paused = f.paused
        s.learned = Array(f.learned.suffix(maxLearned))
        s.learnCandidate = f.learn_candidate.map { LearnCandidate(ids: Set($0.ids), since: $0.since, boot: $0.boot) }
        s.lastError = f.last_error
        s.setBy = f.set_by.map { EngineState.SetRecord(by: $0.by, at: $0.at) }
        return s
    }
}
