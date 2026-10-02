import Darwin
import Foundation
import Security
import ShareScaleNet

/// 複製（`~/Applications/ShareScale.app`）の今の様子
public struct CopyFacts: Equatable, Sendable {
    public var isSymlink: Bool
    public var ownerIsMe: Bool
    public var bundle: BundleFacts
    public init(isSymlink: Bool, ownerIsMe: Bool, bundle: BundleFacts) { self.isSymlink = isSymlink; self.ownerIsMe = ownerIsMe; self.bundle = bundle }

    /// 読む（無ければ nil。リンクはたどらない）
    public static func read(_ copy: URL, uid: uid_t = geteuid(), reader: FileFactsReader = SystemFileFacts()) -> CopyFacts? {
        guard let f = reader.facts(copy.path) else { return nil }
        if f.kind == .symlink { return CopyFacts(isSymlink: true, ownerIsMe: f.uid == uid, bundle: BundleFacts(identifier: nil, version: nil, cdhash: nil)) }
        return CopyFacts(isSymlink: false, ownerIsMe: f.uid == uid, bundle: f.kind == .directory ? BundleFacts.read(copy) : BundleFacts(identifier: nil, version: nil, cdhash: nil))
    }
}

/// Homebrew 側が開かれた時に行うこと（仕様の表。純粋な判定）
public enum InstallPlan: Equatable, Sendable {
    case create
    case replace
    case openCopy
    case abort(CopyProblem)
}

public enum CopyProblem: Equatable, Sendable {
    case symlink, notOwner, wrongIdentifier, unreadableVersion, unsigned

    public var message: String {
        switch self {
        case .unsigned:
            return tr("このアプリの署名を読み取れないため、~/Applications にコピーできません。Homebrew でインストールし直してください。",
                      "This app’s signature can’t be read, so it can’t be copied to ~/Applications. Reinstall it with Homebrew.")
        case .symlink:
            return tr("~/Applications/ShareScale.app がシンボリックリンクのため、置き換えません。ゴミ箱に入れてから、もう一度開いてください。",
                      "~/Applications/ShareScale.app is a symbolic link, so it won’t be replaced. Move it to the Trash, then open ShareScale again.")
        case .notOwner:
            return tr("~/Applications/ShareScale.app がほかのユーザのものであるため、置き換えません。ゴミ箱に入れてから、もう一度開いてください。",
                      "~/Applications/ShareScale.app belongs to another user, so it won’t be replaced. Move it to the Trash, then open ShareScale again.")
        case .wrongIdentifier:
            return tr("~/Applications/ShareScale.app は別のアプリのため、置き換えません。ゴミ箱に入れてから、もう一度開いてください。",
                      "~/Applications/ShareScale.app is a different app, so it won’t be replaced. Move it to the Trash, then open ShareScale again.")
        case .unreadableVersion:
            return tr("~/Applications/ShareScale.app のバージョンを読み取れないため、置き換えません。ゴミ箱に入れてから、もう一度開いてください。",
                      "Can’t read the version of ~/Applications/ShareScale.app, so it won’t be replaced. Move it to the Trash, then open ShareScale again.")
        }
    }
}

public enum Handoff {
    /// Homebrew 側が開かれた時（引き渡しの条件を満たした後）の判定。`own` は Homebrew 側（自分）。
    /// 自分の署名（CDHash）を読めなければ、複製を確かめられないので何もしない（`.unsigned`。仮の値は使わない。点検 K）
    public static func plan(copy: CopyFacts?, own: BundleFacts) -> InstallPlan {
        guard own.cdhash != nil else { return .abort(.unsigned) }
        guard let copy else { return .create }
        if copy.isSymlink { return .abort(.symlink) }
        if !copy.ownerIsMe { return .abort(.notOwner) }
        guard copy.bundle.identifier == AppIdentifiers.app else { return .abort(.wrongIdentifier) }
        guard let theirs = copy.bundle.version, let mine = own.version else { return .abort(.unreadableVersion) }
        if mine > theirs { return .replace }
        if mine == theirs, copy.bundle.cdhash != own.cdhash { return .replace }
        return .openCopy
    }

    /// 複製が起動した時に行うこと（仕様「複製が起動した時」1〜4）
    public enum CopyLaunch: Equatable, Sendable {
        case nothing                        // 記録が無い・Homebrew 側が古いか同じ
        case askUninstall                   // 複製元が消えた（「Homebrew から削除されました。取り除きますか？」）
        case handoff(AppState.Attempt, realPath: String)   // 試みを記録してから Homebrew 側（確かめた実体のパス）を開き、自分は終了
        case alreadyAttempted               // 同じ版と CDHash への引き渡しは試み済み（診断に「更新に失敗しました」）
        case unsafe(HandoffSafety.Problem)  // 引き渡しの条件を満たさない（診断に理由）
        case unreadable                     // 複製元はあるが版・署名を読めない（診断に）
        case notHomebrew                    // 複製元の実体が Homebrew の置き場所の形でない（診断に。開かない）
    }

    /// Homebrew 側の様子（`source` を 1 回だけ解決した実体）
    public enum SourceFacts: Equatable, Sendable {
        case missing
        case unreadable(String)                               // 解決できない（ENOENT・ENOTDIR 以外の理由）
        case present(realPath: String, facts: BundleFacts)
    }

    /// - `safety`: 引き渡しが要る時だけ、解決した実体のパスで呼ぶ（バンドルの中を歩くため）。開くのも同じ実体のパス（点検 D）
    /// - 複製元の署名を読めなければ引き渡さない（`.unreadable`。仮の値は使わない。点検 K）
    public static func copyLaunch(state: AppState, source: SourceFacts?, own: BundleFacts, safety: (String) -> HandoffSafety.Problem?) -> CopyLaunch {
        guard state.source != nil, let source else { return .nothing }
        let real: String, theirs: BundleFacts
        switch source {
        case .missing: return .askUninstall
        case .unreadable: return .unreadable
        case let .present(p, f): real = p; theirs = f
        }
        guard AppLocation.homebrew(real) != nil else { return .notHomebrew }
        guard theirs.identifier == AppIdentifiers.app, let v = theirs.version, let h = theirs.cdhash, let mine = own.version else { return .unreadable }
        let newer = v > mine || (v == mine && h != own.cdhash)
        guard newer else { return .nothing }
        let attempt = AppState.Attempt(build: v, cdhash: h)
        if state.attemptedHandoff == attempt { return .alreadyAttempted }
        if let p = safety(real) { return .unsafe(p) }
        return .handoff(attempt, realPath: real)
    }

    /// 複製元の様子を読む（1 回だけ解決する。無ければ `.missing`。理由は `errno` を後から読まずに受け取る。点検 T）
    public static func readSource(_ path: String) -> SourceFacts {
        switch AppLocation.resolve(path) {
        case let .success(real):
            return .present(realPath: real, facts: BundleFacts.read(URL(fileURLWithPath: real, isDirectory: true)))
        case let .failure(e):
            return e.code == .ENOENT || e.code == .ENOTDIR ? .missing : .unreadable("\(e.code)")
        }
    }
}

/// 複製を作る・置き換える（仕様「置き換えの手順」）。口を差し替えて一時フォルダで試験する
public struct InstallerPorts: Sendable {
    /// 動いている複製に終了を頼み、終わるまで待つ（最大 `timeout` 秒）。終わった（動いていなかった）なら真
    public var terminateRunningCopy: @Sendable (_ copy: URL, _ timeout: Double) async -> Bool
    /// 複製の署名の確かめ（`CodeSignature.verify`。成功なら errSecSuccess）
    public var verify: @Sendable (_ bundle: URL, _ identifier: String, _ cdhash: String) -> OSStatus
    /// 複製する（`FileManager.copyItem`）
    public var copyItem: @Sendable (_ from: URL, _ to: URL) throws -> Void
    public init(terminateRunningCopy: @escaping @Sendable (URL, Double) async -> Bool,
                verify: @escaping @Sendable (URL, String, String) -> OSStatus = { CodeSignature.verify($0, identifier: $1, cdhash: $2) },
                copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) {
        self.terminateRunningCopy = terminateRunningCopy; self.verify = verify; self.copyItem = copyItem
    }
}

public enum AppInstaller {
    public static let terminateTimeout = 5.0

    public enum Failure: Error, Equatable, Sendable {
        case copyStillRunning
        case applicationsFolder(String)
        case copyFailed(String)
        case verifyFailed(OSStatus)
        case swapFailed(Int32)

        public var message: String {
            switch self {
            case .copyStillRunning:
                return tr("~/Applications の ShareScale が終了しませんでした。ShareScale を終了してから、もう一度開いてください。",
                          "ShareScale in ~/Applications didn’t quit. Quit it, then open ShareScale again.")
            case .applicationsFolder:
                return tr("~/Applications フォルダを使えません（ほかの人が書き込めるか、あなたのフォルダでないため）。フォルダの所有者とアクセス権（ほかの人が書き込めないこと）を確認してください。",
                          "The ~/Applications folder can’t be used (others can write to it, or it isn’t yours). Check its owner and permissions so only you can write to it.")
            case .copyFailed, .swapFailed:
                return tr("~/Applications に ShareScale をコピーできませんでした。空き容量とアクセス権を確認してから、もう一度開いてください。",
                          "Couldn’t copy ShareScale to ~/Applications. Check free space and permissions, then open ShareScale again.")
            case .verifyFailed:
                return tr("コピーした ShareScale の署名が元のアプリと一致しないため、使いませんでした。もう一度開いてください。",
                          "The copied ShareScale doesn’t match the original’s signature, so it wasn’t used. Open ShareScale again.")
            }
        }
        /// 生の理由（「詳細をコピー」）
        public var detail: String {
            switch self {
            case .copyStillRunning: return "the running copy didn’t quit within \(Int(AppInstaller.terminateTimeout)) s"
            case let .applicationsFolder(s): return "~/Applications: \(s)"
            case let .copyFailed(s): return "copy: \(s)"
            case let .verifyFailed(s): return "SecStaticCodeCheckValidity: \(s)"
            case let .swapFailed(e): return "renamex_np: \(String(cString: strerror(e)))"
            }
        }
    }

    /// `source`（Homebrew 側の実体）を `copy`（`~/Applications/ShareScale.app`）に置く。`plan` は `.create` か `.replace`。
    /// 1. 動いている複製に終了を頼み最大 5 秒待つ（置き換えの時。終わらなければ中止）
    /// 2. 同じフォルダの一時的な名前（`.ShareScale-install-<pid>-<乱数>`）に複製
    /// 3. 署名を `identifier "io.github.taki-0105a.ShareScale" and cdhash H"<自分の CDHash>"` で確かめる
    /// 4. `renamex_np(RENAME_SWAP)` で不可分に入れ替え（無ければ `RENAME_EXCL` で置く）、一時的な名前に移った旧版を消す
    /// 失敗したら一時的なものを片付けて理由を返す（複製は元のまま）。開くのと自分の終了は呼び出し側
    public static func install(_ plan: InstallPlan, source: URL, copy: URL, ownCDHash: String, ports: InstallerPorts,
                               reader: FileFactsReader = SystemFileFacts()) async -> Result<Void, Failure> {
        let folder = copy.deletingLastPathComponent()
        if let p = prepareFolder(folder, reader: reader) { return .failure(.applicationsFolder(p)) }
        removeStaleTemporaries(in: folder)
        if plan == .replace, !(await ports.terminateRunningCopy(copy, terminateTimeout)) { return .failure(.copyStillRunning) }
        let tmp = folder.appendingPathComponent(".ShareScale-install-\(getpid())-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        do { try ports.copyItem(source, tmp) } catch {
            try? FileManager.default.removeItem(at: tmp)
            return .failure(.copyFailed("\(error)"))
        }
        let status = ports.verify(tmp, AppIdentifiers.app, ownCDHash)
        guard status == errSecSuccess else {
            try? FileManager.default.removeItem(at: tmp)
            return .failure(.verifyFailed(status))
        }
        var r = renamex_np(tmp.path, copy.path, UInt32(RENAME_SWAP))
        var e = errno
        if r != 0, e == ENOENT {    // 複製がまだ無い（同じ時に消されたものを含む）: 置く
            r = renamex_np(tmp.path, copy.path, UInt32(RENAME_EXCL)); e = errno
        }
        guard r == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return .failure(.swapFailed(e))
        }
        // RENAME_SWAP なら一時的な名前に旧版が移っている（RENAME_EXCL なら何も無い）
        try? FileManager.default.removeItem(at: tmp)
        ProtectedFiles.syncFolder(folder)
        return .success(())
    }

    /// `~/Applications` を用意する（無ければ 700 で作る）。本人の本物のフォルダで、グループ・他人が書けず、書き込みを許す ACL が無いものだけを使う
    /// （ほかの利用者が複製を差し替えられる場所に置かないため。点検 E）
    static func prepareFolder(_ dir: URL, reader: FileFactsReader) -> String? {
        var st = stat()
        if lstat(dir.path, &st) != 0 {
            let e = errno
            guard e == ENOENT else { return String(cString: strerror(e)) }
            if mkdir(dir.path, 0o700) != 0, errno != EEXIST { return String(cString: strerror(errno)) }
        }
        guard let f = reader.facts(dir.path) else { return "unreadable" }
        guard f.kind == .directory else { return "not a directory" }
        guard f.uid == geteuid() else { return "owned by another user" }
        guard f.mode & 0o022 == 0 else { return "writable by group or others" }
        guard !f.aclAllowsWrite else { return "an ACL allows others to write" }
        return nil
    }

    /// 前に落ちた入れ替えの一時的なもの（`.ShareScale-install-<pid>-<乱数>`、予備の手順が退避する旧版 `.ShareScale-old-<pid>-<乱数>`。
    /// pid が生きていないもの）を消す（再点検 軽微 2）
    static func removeStaleTemporaries(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            guard let prefix = [".ShareScale-install-", ".ShareScale-old-"].first(where: { name.hasPrefix($0) }) else { continue }
            let parts = name.dropFirst(prefix.count).split(separator: "-")
            guard parts.count == 2, let pid = pid_t(parts[0]), pid > 0 else { continue }
            if pid == getpid() || kill(pid, 0) == 0 || errno == EPERM { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
