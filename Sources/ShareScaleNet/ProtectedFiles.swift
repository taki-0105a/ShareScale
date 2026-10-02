import Darwin
import Foundation

/// 秘密・付帯情報・host-control・engine.json に共通のファイルの守り方（仕様「保管」「同じ Mac の中の受け渡し」）。
/// - フォルダ: 本人・700・通常のフォルダ（無ければ 700 で作る。ほかのプロセスと同時に作っても失敗しない）
/// - 読む: リンクをたどらずに開き（`O_NOFOLLOW`）、開いたものを `fstat` で確かめる（通常ファイル・本人・600 より緩くない・`st_nlink == 1`・上限以下）
/// - 書く: 同じフォルダの一時ファイル（600・`O_CREAT|O_EXCL|O_NOFOLLOW`）に書き、`durable` なら記憶装置まで書き出してから名前を変え、フォルダも書き出す
/// - 一時ファイルの後始末: 名前の pid が自分、または動いているプロセスのものは消さない
///
/// `SecretStore`（`.key`・`.meta`）・`ShareScaleHostCore.HostControlFolder`（`request-*.json`・`state.json`）・
/// `ShareScaleEngine.EngineStateFile`（`engine.json`）が使う（計画 2d-1 で 3 つの写しを一本化した）。
/// 状態を持たない（呼び出し側が自分のロックで直列にする）
public enum ProtectedFiles: Sendable {
    /// フォルダを順に 700 で用意し、確かめる。緩い・他人の・リンクなら使わない（問題のフォルダの道筋と理由を返す）。
    /// `mkdir` の EEXIST は成功として扱い、もう一度確かめる
    public static func prepareFolders(_ dirs: [URL]) -> StoreProblem? {
        for dir in dirs {
            let path = dir.path
            var st = stat()
            if lstat(path, &st) != 0 {
                guard errno == ENOENT else { return StoreProblem(name: path, reason: .folderUnavailable) }
                if mkdir(path, 0o700) != 0 {
                    guard errno == EEXIST else { return StoreProblem(name: path, reason: .folderUnavailable) }
                }
                guard lstat(path, &st) == 0 else { return StoreProblem(name: path, reason: .folderUnavailable) }
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return StoreProblem(name: path, reason: .folderNotDirectory) }
            guard st.st_uid == geteuid() else { return StoreProblem(name: path, reason: .folderWrongOwner) }
            guard st.st_mode & 0o077 == 0 else { return StoreProblem(name: path, reason: .folderLoosePermissions) }
        }
        return nil
    }

    /// リンクをたどらずに開き、開いたものを fstat で確かめてから、終わりまで（最大 `limit` バイト）読む。
    /// 空のファイル・`limit` を超えるものは使わない
    public static func readFile(_ url: URL, limit: Int) -> Result<Data, StoreProblem.Reason> {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ELOOP ? .notRegularFile : .unreadable) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.unreadable) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        guard st.st_uid == geteuid() else { return .failure(.wrongOwner) }
        guard st.st_mode & 0o077 == 0 else { return .failure(.loosePermissions) }
        guard st.st_nlink == 1 else { return .failure(.multipleLinks) }
        guard st.st_size <= limit else { return .failure(.tooLarge) }
        guard let bytes = readAll(fd, limit: limit + 1), !bytes.isEmpty else { return .failure(.unreadable) }
        guard bytes.count <= limit else { return .failure(.tooLarge) }
        return .success(bytes)
    }

    /// 終わりまで（最大 `limit` バイト）読む。EINTR はやり直し、短い読み取りは続けて読む。失敗なら nil
    public static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: min(limit, 64 * 1024))
        while out.count < limit {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, limit - out.count)) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// すべて書く。EINTR はやり直し、短い書き込みは残りを続けて書く。失敗なら errno（0 なら成功）
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int32 {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 { if errno == EINTR { continue }; return errno }
            if n == 0 { return EIO }
            offset += n
        }
        return 0
    }

    /// 記憶装置まで書き出す（`F_FULLFSYNC`。使えないファイルシステムでは fsync）。失敗なら errno（0 なら成功）
    public static func fullSync(_ fd: Int32) -> Int32 {
        if fcntl(fd, F_FULLFSYNC) == 0 { return 0 }
        return fsync(fd) == 0 ? 0 : errno
    }

    /// フォルダを記憶装置まで書き出す（名前を変えた後に呼ぶ。開けなければ何もしない）
    public static func syncFolder(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { _ = fullSync(fd); close(fd) }
    }

    /// 同じフォルダの一時ファイル `temporaryName`（600・`O_EXCL`・`O_NOFOLLOW`）に書いて名前を変える。
    /// `durable` なら記憶装置まで書き出してから名前を変え、フォルダも書き出す（秘密・指示は durable、`state.json` のような写しは durable でなくてよい）。
    /// 失敗なら errno（0 なら成功。失敗した時は一時ファイルを消す）
    public static func writeReplacing(_ final: URL, temporaryName: String, bytes: [UInt8], durable: Bool) -> Int32 {
        let dir = final.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(temporaryName).path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return errno }
        // errno は失敗した呼び出しの直後に保存する（close・unlink が書き換えるため）
        var failure = writeAll(fd, bytes)
        if failure == 0, durable { failure = fullSync(fd) }
        close(fd)
        if failure == 0, rename(tmp, final.path) != 0 { failure = errno }
        if failure != 0 { unlink(tmp); return failure }
        if durable { syncFolder(dir) }
        return 0
    }

    /// 書き込みの途中で落ちたプロセスの一時ファイルを消す。`owner` は、名前が一時ファイルの形ならその pid（読めなければ `.some(nil)`）、
    /// 形が違えば nil を返す。名前の pid が自分、または動いているプロセス（`kill(pid, 0)` が成功か EPERM）のものは、書き込み中かもしれないので消さない
    /// （落ちたプロセスの pid が別のプロセスに使い回されていると、そのプロセスが終わるまで残る。フォルダは 700 なので害は小さい）。
    /// リンクならリンクだけを消す（たどらない）
    public static func removeStaleTemporaries(in dir: URL, owner: (String) -> pid_t??) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            guard let o = owner(name) else { continue }
            if let pid = o {
                if pid == getpid() { continue }
                if kill(pid, 0) == 0 || errno == EPERM { continue }
            }
            unlink(dir.appendingPathComponent(name).path)
        }
    }

    /// pid が生きているか（`kill(pid, 0)` が成功か EPERM）。`state.json` の `pid` の生存確認にも使う
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
