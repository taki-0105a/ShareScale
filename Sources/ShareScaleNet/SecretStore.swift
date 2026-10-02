import Darwin
import Foundation
import IOKit
import ShareScaleProtocol

public enum PairingRole: String, Sendable {
    case host     // この Mac の Host が受け入れる見る側（pairings/host/）
    case viewer   // この Mac が使う接続先（pairings/viewer/）
}

public struct StoredPairing: Equatable, Sendable {
    public let id: PairingID
    public let secret: Bytes32
    public init(id: PairingID, secret: Bytes32) { self.id = id; self.secret = secret }
}

/// 読み込みで使わなかったペアリングと理由（診断に出す。起動は止めない）
public struct StoreProblem: Equatable, Sendable {
    public enum Reason: String, Error, Sendable {
        case notRegularFile, wrongOwner, loosePermissions, multipleLinks, tooLarge, unreadable
        case badFormat, roleMismatch, idMismatch, otherMachine
        case folderNotDirectory, folderWrongOwner, folderLoosePermissions, folderUnavailable
    }
    public let name: String
    public let reason: Reason
    public init(name: String, reason: Reason) { self.name = name; self.reason = reason }
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case folder(StoreProblem.Reason)
    case limitReached
    case writeFailed(Int32)
}

/// ペアリングの秘密の保管（仕様「保管」）。キーチェーンは使わない（試作 3）。フォルダ 700・ファイル 600。
/// 同じ役割のフォルダを指すインスタンスは、同じプロセスの中では 1 つのロックを共有する（道筋ごとにプロセス全体で 1 つ）。
/// 記憶の中の可変の状態は持たない（フォルダ・ファイルの読み書きを、道筋ごとの `lock` で直列にする）
public final class SecretStore: @unchecked Sendable {
    public let base: URL          // ~/Library/Application Support/ShareScale
    public let role: PairingRole
    public let machine: String    // この Mac の IOPlatformUUID
    let maxFileBytes = 1024
    private let lock: NSLock

    public init(base: URL, role: PairingRole, machine: String) {
        self.base = base; self.role = role; self.machine = machine
        self.lock = Self.sharedLock(for: base.appendingPathComponent("pairings/\(role.rawValue)", isDirectory: true).resolvingSymlinksInPath().path)   // /var と /private/var を同じロックにする
    }

    /// 役割のフォルダの道筋ごとのロック（プロセス全体の表）
    private static let lockTable = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]
    private static func sharedLock(for path: String) -> NSLock {
        lockTable.withLock {
            if let l = locks[path] { return l }
            let l = NSLock(); locks[path] = l; return l
        }
    }

    /// 既定の置き場所とこの Mac の識別子で作る
    public static func standard(role: PairingRole) -> SecretStore? {
        guard let uuid = MachineIdentity.platformUUID() else { return nil }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ShareScale", isDirectory: true)
        return SecretStore(base: base, role: role, machine: uuid)
    }

    var pairingsDir: URL { base.appendingPathComponent("pairings", isDirectory: true) }
    var roleDir: URL { pairingsDir.appendingPathComponent(role.rawValue, isDirectory: true) }

    /// フォルダ（ShareScale/・pairings/・host|viewer/）を 700 で用意し、確かめる（`ProtectedFiles.prepareFolders`）。
    /// 問題があれば、そのフォルダの道筋と理由を返す。
    /// `pairings/` のバックアップ除外は、作った時だけでなく毎回確かめて付ける（すでに付いていれば何もしない）
    func prepareFolders() -> StoreProblem? {
        if let p = ProtectedFiles.prepareFolders([base, pairingsDir, roleDir]) { return p }
        var u = pairingsDir
        if (try? u.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) != true {
            var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v)
        }
        return nil
    }

    /// 自分の役割のフォルダに残った一時ファイル（`.<id>.<pid>.<乱数>.tmp`。書き込みの途中で落ちた時のもの。秘密を含む）を消す
    /// （`ProtectedFiles.removeStaleTemporaries`。自分と動いているプロセスのものは消さない）
    private func removeStaleTemporaries() {
        ProtectedFiles.removeStaleTemporaries(in: roleDir, owner: Self.temporaryOwner)
    }

    /// 一時ファイルの名前（`.` ＋ 32 文字の小文字 hex ＋ `.` … `.tmp`）なら、名前の pid（読めなければ nil）を返す。形が違えば nil
    static func temporaryOwner(_ name: String) -> pid_t?? {
        let u = Array(name.utf8)
        let hex = Array("0123456789abcdef".utf8)
        guard u.count > 1 + Limits.idHexLength + 1 + 4, u[0] == UInt8(ascii: "."), name.hasSuffix(".tmp"),
              u[1...Limits.idHexLength].allSatisfy(hex.contains), u[Limits.idHexLength + 1] == UInt8(ascii: ".") else { return nil }
        let rest = name.dropFirst(1 + Limits.idHexLength + 1).dropLast(4)
        guard let field = rest.split(separator: ".", omittingEmptySubsequences: false).first,
              field.allSatisfy(\.isASCII), field.allSatisfy(\.isNumber), let pid = pid_t(field), pid > 0 else { return .some(nil) }
        return .some(pid)
    }

    static func isTemporaryName(_ name: String) -> Bool { temporaryOwner(name) != nil }

    /// 役割のフォルダの `.key` の数（読めないものも数える。`save` の上限の数え方と同じ）。フォルダが使えなければ nil
    public func keyCount() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard prepareFolders() == nil, let names = try? FileManager.default.contentsOfDirectory(atPath: roleDir.path) else { return nil }
        return names.filter { $0.hasSuffix(".key") }.count
    }

    /// 使えるペアリングと、使わなかったものの理由
    public func loadAll() -> (pairings: [StoredPairing], problems: [StoreProblem]) {
        lock.lock(); defer { lock.unlock() }
        if let f = prepareFolders() { return ([], [f]) }
        removeStaleTemporaries()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: roleDir.path) else {
            return ([], [StoreProblem(name: roleDir.path, reason: .folderUnavailable)])
        }
        var ok: [StoredPairing] = [], problems: [StoreProblem] = []
        for name in names.sorted() where name.hasSuffix(".key") {
            switch read(name) {
            case let .success(p): ok.append(p)
            case let .failure(r): problems.append(StoreProblem(name: name, reason: r))
            }
        }
        return (ok, problems)
    }

    /// 役割のフォルダの 1 ファイルを読む（`.key`・`.meta` で同じ確かめ方。`ProtectedFiles.readFile`）
    private func readFile(_ name: String, limit: Int) -> Result<Data, StoreProblem.Reason> {
        ProtectedFiles.readFile(roleDir.appendingPathComponent(name), limit: limit)
    }

    private func read(_ name: String) -> Result<StoredPairing, StoreProblem.Reason> {
        var bytes: Data
        switch readFile(name, limit: maxFileBytes) {
        case let .success(b): bytes = b
        case let .failure(r): return .failure(r)
        }
        if bytes.last == 0x0A { bytes.removeLast() }
        guard let m = (try? StrictJSON.parse(bytes))?.exactKeys(["format", "role", "id", "k", "machine"]),
              case .integer(1)? = m["format"], case let .string(r)? = m["role"], case let .string(idHex)? = m["id"],
              case let .string(k)? = m["k"], case let .string(mach)? = m["machine"],
              let id = PairingID(hex: idHex), let secret = Bytes32(base64URL: k) else { return .failure(.badFormat) }
        guard r == role.rawValue else { return .failure(.roleMismatch) }
        guard name == idHex + ".key" else { return .failure(.idMismatch) }
        guard mach == machine else { return .failure(.otherMachine) }
        return .success(StoredPairing(id: id, secret: secret))
    }

    /// 作成・取り替え。一時ファイル（600・O_EXCL・O_NOFOLLOW）に書いて記憶装置まで書き出し、名前を変え、フォルダも書き出す。
    ///
    /// 上限（32 件）の数え方: 置き換えでなく新しく作る時だけ、役割のフォルダの `.key` の数を数える。
    /// 同じプロセスの中では、道筋ごとのロックで数えてから名前を変えるまでを守る。別のプロセスとの間では競合しうる
    /// （Host と見る側は別の役割のフォルダを使い、同じ役割のフォルダを 2 つのプロセスが同時に書かない前提で正しい）
    public func save(_ p: StoredPairing) throws {
        lock.lock(); defer { lock.unlock() }
        if let f = prepareFolders() { throw SecretStoreError.folder(f.reason) }
        removeStaleTemporaries()
        let final = roleDir.appendingPathComponent(p.id.hex + ".key").path
        if access(final, F_OK) != 0 {
            let count = ((try? FileManager.default.contentsOfDirectory(atPath: roleDir.path)) ?? []).filter { $0.hasSuffix(".key") }.count
            guard count < Limits.maxPairings else { throw SecretStoreError.limitReached }
        }
        let json = JSONWriter.write(.object([
            ("format", .integer(1)), ("role", .string(role.rawValue)), ("id", .string(p.id.hex)),
            ("k", .string(Base64URL.encode(p.secret.data))), ("machine", .string(machine)),
        ])) + "\n"
        try writeReplacing(final, id: p.id, bytes: Array(json.utf8))
    }

    /// 一時ファイル（600・O_EXCL・O_NOFOLLOW。名前は `.<id>.<pid>.<乱数>.tmp`）に書いて記憶装置まで書き出し、名前を変え、フォルダも書き出す
    /// （`ProtectedFiles.writeReplacing(durable: true)`）
    private func writeReplacing(_ final: String, id: PairingID, bytes: [UInt8]) throws {
        let e = ProtectedFiles.writeReplacing(URL(fileURLWithPath: final), temporaryName: ".\(id.hex).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp",
                                             bytes: bytes, durable: true)
        if e != 0 { throw SecretStoreError.writeFailed(e) }
    }

    // ---- 付帯情報（`<id>.meta`。中身の形は使う側が決める。秘密のファイルとは別に書き、秘密のファイルは書き直さない）----

    let maxMetaBytes = 4096

    /// 付帯情報をすべて読む（秘密のファイルと同じ確かめ方。対になる `.key` があるかは見ない）
    public func loadMetas() -> (metas: [PairingID: Data], problems: [StoreProblem]) {
        lock.lock(); defer { lock.unlock() }
        if let f = prepareFolders() { return ([:], [f]) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: roleDir.path) else {
            return ([:], [StoreProblem(name: roleDir.path, reason: .folderUnavailable)])
        }
        var metas: [PairingID: Data] = [:], problems: [StoreProblem] = []
        for name in names.sorted() where name.hasSuffix(".meta") {
            guard let id = PairingID(hex: String(name.dropLast(5))) else { problems.append(StoreProblem(name: name, reason: .idMismatch)); continue }
            switch readFile(name, limit: maxMetaBytes) {
            case let .success(d): metas[id] = d
            case let .failure(r): problems.append(StoreProblem(name: name, reason: r))
            }
        }
        return (metas, problems)
    }

    /// 付帯情報を書く（作成・置き換え。一時ファイルから入れ替える）。4 KiB を超えるものは書かない
    public func saveMeta(_ id: PairingID, _ contents: Data) throws {
        guard contents.count <= maxMetaBytes else { throw SecretStoreError.writeFailed(EFBIG) }
        lock.lock(); defer { lock.unlock() }
        if let f = prepareFolders() { throw SecretStoreError.folder(f.reason) }
        try writeReplacing(roleDir.appendingPathComponent(id.hex + ".meta").path, id: id, bytes: [UInt8](contents))
    }

    /// 付帯情報だけを消す（無ければ何もしない）。解除の知らせより後に届いた照合の知らせで書かれた `.meta` の後始末に使う
    public func deleteMeta(_ id: PairingID) throws {
        lock.lock(); defer { lock.unlock() }
        if let f = prepareFolders() { throw SecretStoreError.folder(f.reason) }
        if unlink(roleDir.appendingPathComponent(id.hex + ".meta").path) != 0 {
            let e = errno
            guard e == ENOENT else { throw SecretStoreError.writeFailed(e) }
            return
        }
        syncFolder()
    }

    /// 削除（ゴミ箱には移さない。ゴミ箱の中でも有効な資格情報のため）。`.key` を消してから `.meta` を消し、フォルダを書き出す。
    /// `.key` を消せなければ throw（`.meta` は消さない）。`.meta` を消せなくても throw しない（秘密は消えている。残った `.meta` は使われない）
    public func delete(_ id: PairingID) throws {
        lock.lock(); defer { lock.unlock() }
        if let f = prepareFolders() { throw SecretStoreError.folder(f.reason) }
        let path = roleDir.appendingPathComponent(id.hex + ".key").path
        if unlink(path) != 0 {
            let e = errno
            guard e == ENOENT else { throw SecretStoreError.writeFailed(e) }
        }
        unlink(roleDir.appendingPathComponent(id.hex + ".meta").path)
        syncFolder()
    }

    private func syncFolder() { ProtectedFiles.syncFolder(roleDir) }
}

/// この Mac の識別子（移行アシスタントで別の Mac に写ったペアリングを見分けるため）
public enum MachineIdentity {
    public static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
