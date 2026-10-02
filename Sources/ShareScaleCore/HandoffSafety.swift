import Darwin
import Foundation

/// ファイルの情報（`lstat` と ACL の有無。リンクはたどらない）
public struct FileFacts: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case directory, regular, symlink, other }
    public var kind: Kind
    public var uid: uid_t
    public var gid: gid_t
    public var mode: mode_t      // 権限のビット（`st_mode & 0o7777`）
    public var hasACL: Bool
    /// 書き込み（追加・削除・書き換え・権限や持ち主の変更）を許す ACL の項目があるか（`~/Applications` の確かめ。点検 E）
    public var aclAllowsWrite: Bool
    public init(kind: Kind, uid: uid_t, gid: gid_t, mode: mode_t, hasACL: Bool, aclAllowsWrite: Bool = false) {
        self.kind = kind; self.uid = uid; self.gid = gid; self.mode = mode; self.hasACL = hasACL; self.aclAllowsWrite = aclAllowsWrite
    }
}

/// ファイルの情報を読む口（試験では差し替える）
public protocol FileFactsReader: Sendable {
    /// リンクをたどらない情報（無い・読めなければ nil）
    func facts(_ path: String) -> FileFacts?
    /// フォルダの中の名前（読めなければ nil）
    func children(_ path: String) -> [String]?
}

/// 実物の口（`lstat`・`acl_get_link_np`）
public struct SystemFileFacts: FileFactsReader {
    public init() {}
    public func facts(_ path: String) -> FileFacts? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind: FileFacts.Kind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regular
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let acl = Self.acl(path)
        return FileFacts(kind: kind, uid: st.st_uid, gid: st.st_gid, mode: st.st_mode & 0o7777, hasACL: acl.any, aclAllowsWrite: acl.allowsWrite)
    }
    public func children(_ path: String) -> [String]? { try? FileManager.default.contentsOfDirectory(atPath: path) }

    /// 拡張の ACL に項目が 1 つでもあるか・書き込みを許す項目があるか（リンクはたどらない）。
    /// 読めない（ACL が無い＝ENOENT 以外の失敗）・項目の種類や権限を読めない時は「書き込みを許す」に倒す（使わない側。再点検 軽微 5）。
    /// `read` は試験で失敗を差し込む口
    static func acl(_ path: String, read: (String) -> (acl: acl_t?, errno: Int32) = { p in
        let a = acl_get_link_np(p, ACL_TYPE_EXTENDED)
        return (a, a == nil ? errno : 0)
    }) -> (any: Bool, allowsWrite: Bool) {
        let r = read(path)
        guard let acl = r.acl else { return r.errno == ENOENT ? (false, false) : (true, true) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
                                    ACL_WRITE_SECURITY, ACL_CHANGE_OWNER, ACL_ADD_SUBDIRECTORY]   // ACL_ADD_FILE は ACL_WRITE_DATA と同じビット
        var any = false, allowsWrite = false
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let e = entry {
            any = true
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(e, &tag) == 0 else { allowsWrite = true; continue }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            var perms: acl_permset_t?
            guard acl_get_permset(e, &perms) == 0, let p = perms else { allowsWrite = true; continue }
            if writes.contains(where: { acl_get_perm_np(p, $0) == 1 }) { allowsWrite = true }
        }
        return (any, allowsWrite)
    }
}

/// 引き渡しの条件（仕様「引き渡しの条件」。Homebrew 側から複製を作る・置き換える時と、複製が Homebrew 側を開く時の両方で確かめる）。
/// - バンドルの中のすべての項目: 所有者が本人、グループ・他人が書き込めない、ACL が無い、シンボリックリンクでない（判断の記録）
/// - バンドルから `/` までの上位のフォルダ: 所有者が本人か root、他人が書き込めない、グループの書き込みはグループが gid 80（admin）の時だけ、ACL が無い
/// 満たさなければ理由を返す（満たせば nil）。純粋な判定で、ファイルの情報は `FileFactsReader` から読む
public enum HandoffSafety {
    public static let adminGroup: gid_t = 80
    /// バンドルの中を見る項目数の上限（これを超えるものは満たさないとみなす）
    public static let maxItems = 20_000

    public enum Problem: Equatable, Sendable {
        case unreadable(String)
        case wrongOwner(String)
        case writableByOthers(String)
        case aclPresent(String)
        case symlinkInside(String)
        case tooManyItems

        /// 生の理由（「詳細をコピー」。どのパスで何が合わないか）
        public var detail: String {
            switch self {
            case let .unreadable(p): return "unreadable: \(p)"
            case let .wrongOwner(p): return "owner is not you: \(p)"
            case let .writableByOthers(p): return "writable by others: \(p)"
            case let .aclPresent(p): return "has an ACL: \(p)"
            case let .symlinkInside(p): return "symbolic link inside the bundle: \(p)"
            case .tooManyItems: return "too many items in the bundle"
            }
        }
    }

    /// 案内の本文（Homebrew 側・複製の診断で共通）
    public static var message: String {
        tr("Homebrew のフォルダがほかのユーザのものか、ほかの人が書き込めるため、自動では置き換えません。ソースから scripts/build-sharescale.sh --install でインストールしてください。",
           "The Homebrew folder belongs to another user or others can write to it, so ShareScale won’t replace itself automatically. Install from source with scripts/build-sharescale.sh --install.")
    }

    /// `bundle` はシンボリックリンクを解決した実体のパス（`AppLocation.realPath`）
    public static func check(bundle: String, uid: uid_t, reader: FileFactsReader) -> Problem? {
        if let p = checkBundle(bundle, uid: uid, reader: reader) { return p }
        var dir = (bundle as NSString).deletingLastPathComponent
        while true {
            guard let f = reader.facts(dir) else { return .unreadable(dir) }
            guard f.kind == .directory else { return .unreadable(dir) }
            guard f.uid == uid || f.uid == 0 else { return .wrongOwner(dir) }
            if f.mode & 0o002 != 0 { return .writableByOthers(dir) }
            if f.mode & 0o020 != 0, f.gid != adminGroup { return .writableByOthers(dir) }
            if f.hasACL { return .aclPresent(dir) }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    /// バンドルの中（バンドルのフォルダ自身を含む）を深さ優先で見る。開発の組み立てから登録する時も、自分のバンドルにこれだけを当てる
    /// （上位のフォルダは確かめない。ホームには既定で ACL が付いているため。点検 I）
    public static func checkBundle(_ bundle: String, uid: uid_t, reader: FileFactsReader) -> Problem? {
        var stack = [bundle]
        var seen = 0
        while let path = stack.popLast() {
            seen += 1
            if seen > maxItems { return .tooManyItems }
            guard let f = reader.facts(path) else { return .unreadable(path) }
            if f.kind == .symlink { return .symlinkInside(path) }
            guard f.uid == uid else { return .wrongOwner(path) }
            if f.mode & 0o022 != 0 { return .writableByOthers(path) }
            if f.hasACL { return .aclPresent(path) }
            if f.kind == .directory {
                guard let names = reader.children(path) else { return .unreadable(path) }
                stack.append(contentsOf: names.sorted().reversed().map { path + "/" + $0 })
            }
        }
        return nil
    }
}
