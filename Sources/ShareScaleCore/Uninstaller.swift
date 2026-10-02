import Combine
import Darwin
import Foundation
import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// Host が動いているかの読み取り（`state.json`）。読めない時は「分からない」（止まったとはみなさない。点検 A）
public enum HostLiveness: Equatable, Sendable {
    case running, stopped, unknown

    public init(_ s: HostControlClient.HostState) {
        switch s {
        case .running: self = .running
        case .notRunning: self = .stopped
        case .unknown: self = .unknown
        }
    }
}

/// 取り除きの口（試験では差し替える。実物の登録の解除・ゴミ箱・環境設定・通信に触れない）
public struct UninstallPorts: Sendable {
    public var loginItem: LoginItemService
    /// 「ログイン時に ShareScale を開く」（`SMAppService.mainApp`。計画 2f-2）。nil なら触れない
    public var appLoginItem: LoginItemService?
    /// Host が動いているか（`state.json` の `running` と `pid` の生存。読めなければ `.unknown`）
    public var hostState: @Sendable () -> HostLiveness
    /// Host の識別子のプロセスが動いているか（`NSRunningApplication`。`state.json` が無い・古くても、プロセスで確かめる。点検 A）
    public var hostProcessRunning: @Sendable () -> Bool
    /// Host に終了を頼む（host-control の `quit`。ログイン項目からでなく開かれた Host のため）
    public var askHostToQuit: @Sendable () -> Void
    /// 接続先に `unpair` を送ってから消す（`ViewerTargets.remove`）
    public var unpair: @Sendable (PairingID) async -> TargetRemoval
    /// ゴミ箱へ移す（`FileManager.trashItem`）
    public var trash: @Sendable (URL) throws -> Void
    /// 環境設定の域を消す（`UserDefaults.removePersistentDomain(forName:)`）
    public var removeDefaults: @Sendable (String) -> Void
    public var sleep: @Sendable (Double) async -> Void
    /// 実物の組み立て（ShareScale.app が使う）。Host の生存は `state.json`（`client`）と、Host の識別子のプロセス（`isRunning`。実行体が
    /// `NSRunningApplication` で答える）の両方で見る。ゴミ箱は `FileManager.trashItem`、環境設定は `UserDefaults.removePersistentDomain`（再点検 軽微 6）
    public static func system(client: HostControlClient, unpair: @escaping @Sendable (PairingID) async -> TargetRemoval,
                              isRunning: @escaping @Sendable (_ bundleIdentifier: String) -> Bool) -> UninstallPorts {
        UninstallPorts(loginItem: SystemLoginItemService(),
                       appLoginItem: SystemAppLoginItemService(),
                       hostState: { HostLiveness(client.hostState()) },
                       hostProcessRunning: { isRunning(AppIdentifiers.host) },
                       askHostToQuit: { try? client.quit() },
                       unpair: unpair,
                       trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                       removeDefaults: { UserDefaults.standard.removePersistentDomain(forName: $0) })
    }

    public init(loginItem: LoginItemService, appLoginItem: LoginItemService? = nil,
                hostState: @escaping @Sendable () -> HostLiveness, hostProcessRunning: @escaping @Sendable () -> Bool,
                askHostToQuit: @escaping @Sendable () -> Void,
                unpair: @escaping @Sendable (PairingID) async -> TargetRemoval, trash: @escaping @Sendable (URL) throws -> Void,
                removeDefaults: @escaping @Sendable (String) -> Void,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.loginItem = loginItem; self.appLoginItem = appLoginItem
        self.hostState = hostState; self.hostProcessRunning = hostProcessRunning; self.askHostToQuit = askHostToQuit; self.unpair = unpair
        self.trash = trash; self.removeDefaults = removeDefaults; self.sleep = sleep
    }
}

/// 取り除きの結果
public struct UninstallReport: Equatable, Sendable {
    /// 中止した理由（中止しなければ nil）と、コピーできる生の理由
    public var aborted: String?
    public var abortDetail: String?
    /// `unpair` が届かなかった接続先の名前（「次の接続先のメニューからも解除してください」）
    public var unreachable: [String] = []
    /// ゴミ箱に移せなかったもの
    public var leftovers: [String] = []
    public var appTrashed = false
    /// 「ログイン時に ShareScale を開く」の登録を外せなかった（計画 2f-2。ほかは続ける）
    public var appLoginItemLeft = false
    /// 表示する `brew uninstall sharescale`（Homebrew から削除済みなら nil）
    public var brewCommand: String?
    public init() {}
    public var completed: Bool { aborted == nil && leftovers.isEmpty && appTrashed && !appLoginItemLeft }

    /// 画面の見出しと本文
    public var summary: (title: String, detail: String) {
        if let a = aborted { return (tr("完全な削除を中止しました", "Removal stopped"), a) }
        var parts: [String] = []
        // 一覧は文の末尾の「: 」の後に並べず、文の中に入れる（長い文の最後に名前だけが残らないように。仕上げ 2026-09-30）
        if !leftovers.isEmpty {
            let list = leftovers.joined(separator: tr("、", ", "))
            parts.append(tr("次の項目をゴミ箱に入れられませんでした: \(list)。アクセス権を確認してから、もう一度「ShareScale を完全に削除…」を選択してください（アプリはまだ残しています）。",
                            "These items couldn’t be moved to the Trash: \(list). Check permissions, then choose Remove ShareScale Completely… again (the app is kept for now)."))
        }
        if appLoginItemLeft {
            parts.append(tr("ログイン時に開く ShareScale の登録を解除できませんでした。システム設定 › 一般 › ログイン項目で ShareScale を削除してください。",
                            "Couldn’t stop ShareScale from opening at login. Remove ShareScale in System Settings › General › Login Items."))
        }
        if !unreachable.isEmpty {
            let names = unreachable.map { tr("「\($0)」", "“\($0)”") }.joined(separator: tr("", ", "))
            parts.append(unreachable.count == 1
                         ? tr("\(names)に接続できなかったため、その Mac の ShareScale Host のメニューでも、この Mac の登録を解除してください。",
                              "Couldn’t connect to \(names), so also remove this Mac in the ShareScale Host menu on that Mac.")
                         : tr("\(names)に接続できなかったため、それぞれの ShareScale Host のメニューでも、この Mac の登録を解除してください。",
                              "Couldn’t connect to \(names), so also remove this Mac in the ShareScale Host menu on each of them."))
        }
        if brewCommand != nil {   // コマンドそのものは画面がコピーできる形で下に出す
            parts.append(tr("最後に、ターミナルで下のコマンドを実行して Homebrew からも削除してください。", "Finally, run the command below in Terminal to remove it from Homebrew too."))
        }
        let title = completed ? tr("ShareScale を完全に削除しました", "ShareScale was removed completely") : tr("ShareScale の一部を削除しました", "ShareScale was partly removed")
        return (title, parts.isEmpty ? tr("ShareScale を終了します。", "ShareScale will quit.") : parts.joined(separator: "\n"))
    }
}

/// 「ShareScale を取り除く」（仕様「解除と取り除き」の 1〜7。複製だけが行う）。各段の扱い（判断の記録）:
/// 1. Host の登録を解除し、Host のプロセスが終わったことを確かめる（最大 10 秒。2 秒たっても動いていれば host-control の `quit` も頼む）。
///    解除できない・終わらなければ**中止**（何も消さない）
/// 2. 接続先それぞれに `unpair`（届かない・消せなければ一覧に。**続ける**）
/// 3. `pairings/host/`・`pairings/viewer/` の秘密（`.key` を先に、次に `.meta` と一時ファイル）を**削除**（ゴミ箱に移さない）。`.key` か `.tmp` が 1 つでも残れば**中止**
///    （残りをゴミ箱に移すと、秘密がゴミ箱に入るため）
/// 4. 残りの `Application Support/ShareScale/`・`Logs/ShareScale/`・環境設定（2 つの域を消してから plist）・`savedState` をゴミ箱へ（無いものは飛ばす。移せなければ一覧に）
/// 5. 4 で残ったものが無ければ `~/Applications/ShareScale.app` をゴミ箱へ（残ったものがあればアプリは残し、もう一度取り除けるようにする）
/// 6. `brew uninstall sharescale` を表示する（実行しない。Homebrew から削除済みなら出さない）
/// 7. 終了は画面が行う（結果を見せてから）
/// 途中で止まっても、次に開いた時に続きから取り除ける（無いものは飛ばす）
@MainActor
public final class Uninstaller: ObservableObject {
    public enum Phase: Equatable, Sendable { case stoppingHost, unpairing, deletingSecrets, trashing, finished }
    @Published public private(set) var phase: Phase?
    @Published public private(set) var report: UninstallReport?

    public let paths: AppPaths
    private let ports: UninstallPorts
    public static let hostStopTimeout = 10.0
    public static let quitRequestAfter = 2.0
    public static let pollInterval = 0.25

    public init(paths: AppPaths, ports: UninstallPorts) { self.paths = paths; self.ports = ports }

    /// 確かめの窓に出す一覧（何が消えるか）
    public static func plannedItems(paths: AppPaths, targetNames: [String], homebrewRemoved: Bool) -> [String] {
        var out = [tr("ログイン項目の ShareScale Host と、ログイン時に開く ShareScale の登録を解除し、ShareScale Host を終了します",
                      "Remove ShareScale Host and ShareScale from Login Items, and quit ShareScale Host")]
        if !targetNames.isEmpty {
            out.append(tr("接続先 \(targetNames.count) 台に、この Mac の登録を解除するよう伝えます: ", "Ask \(HostLanguage.count(targetNames.count, "target", "targets")) to remove this Mac: ")
                       + targetNames.joined(separator: tr("、", ", ")))
        }
        out.append(tr("ペアリングの鍵を削除します（ゴミ箱には入れません）: ", "Delete pairing keys (not moved to the Trash): ") + tilde(paths.pairings, paths))
        for u in [paths.support, paths.logs] + paths.preferenceFiles + [paths.savedState, paths.copy] {
            out.append(tr("ゴミ箱に入れる: ", "Move to the Trash: ") + tilde(u, paths))
        }
        if !homebrewRemoved {
            out.append(tr("最後に brew uninstall sharescale の実行を案内します（アプリからは実行しません）", "Finally, show brew uninstall sharescale for you to run (the app doesn’t run it)"))
        }
        return out
    }

    static func tilde(_ u: URL, _ paths: AppPaths) -> String {
        let home = paths.home.path
        return u.path.hasPrefix(home + "/") ? "~" + u.path.dropFirst(home.count) : u.path
    }

    /// 取り除く。`targets` は見る側の帳簿の接続先（id と表示名）
    @discardableResult
    public func run(targets: [(id: PairingID, name: String)], homebrewRemoved: Bool) async -> UninstallReport {
        var r = UninstallReport()
        defer { report = r; phase = .finished }
        // 1. Host を止める（登録を外せたか、外した後に止まったと確かめられなかったかで文を分ける。点検 M）
        phase = .stoppingHost
        switch await stopHost() {
        case .stopped: break
        case let .notUnregistered(detail):
            r.aborted = tr("ログイン項目の登録を解除できなかったため、何も削除していません。システム設定 › 一般 › ログイン項目を確認してから、もう一度選択してください。",
                           "Couldn’t remove the login item, so nothing was deleted. Check System Settings › General › Login Items, then try again.")
            r.abortDetail = detail
            return r
        case let .notConfirmed(unregistered, detail):
            r.aborted = unregistered
                ? tr("ログイン項目の登録は解除しましたが、ShareScale Host が停止したことを確認できなかったため、ほかのものは削除していません。ShareScale Host のメニューから終了してから、もう一度選択してください。",
                     "The login item was removed, but ShareScale Host couldn’t be confirmed as stopped, so nothing else was deleted. Quit it from the ShareScale Host menu, then try again.")
                : tr("ShareScale Host が停止したことを確認できなかったため、何も削除していません。ShareScale Host のメニューから終了してから、もう一度選択してください。",
                     "ShareScale Host couldn’t be confirmed as stopped, so nothing was deleted. Quit it from the ShareScale Host menu, then try again.")
            r.abortDetail = detail
            return r
        }
        // 1b. 「ログイン時に ShareScale を開く」の登録を外す（計画 2f-2）。外せなくても続け、結果に書く（アプリを消した後の登録は開けないだけで害は無い）
        if let a = ports.appLoginItem {
            let s = a.status()
            if s != .notRegistered, s != .notFound {
                do { try a.unregister() } catch {
                    let after = a.status()
                    if after != .notRegistered, after != .notFound { r.appLoginItemLeft = true }
                }
            }
        }
        // 2. 接続先に解除を伝える
        phase = .unpairing
        for t in targets {
            switch await ports.unpair(t.id) {
            case .removed, .alreadyRemoved: break
            case .removedLocally, .failed: r.unreachable.append(t.name)
            }
        }
        // 3. 秘密を削除する
        phase = .deletingSecrets
        if let problem = Self.deleteSecrets(support: paths.support) {
            r.aborted = tr("ログイン項目の登録を解除し、接続先に登録の解除を伝えましたが、ペアリングの鍵を削除できなかったため、ほかのものは削除していません。~/Library/Application Support/ShareScale/pairings/ の中身とアクセス権を確認してから、もう一度選択してください。",
                           "The login item and the pairings with targets were removed, but pairing keys couldn’t be deleted, so nothing else was deleted. Check the contents and permissions under ~/Library/Application Support/ShareScale/pairings/, then try again.")
            r.abortDetail = problem
            return r
        }
        // 4. 残りをゴミ箱へ
        phase = .trashing
        for u in [paths.support, paths.logs] { trashIfPresent(u, &r) }
        ports.removeDefaults(AppIdentifiers.app)
        ports.removeDefaults(AppIdentifiers.host)
        for u in paths.preferenceFiles + [paths.savedState] { trashIfPresent(u, &r) }
        // 5. アプリ（4 で残ったものが無い時だけ）
        if r.leftovers.isEmpty {
            if exists(paths.copy) {
                do { try ports.trash(paths.copy); r.appTrashed = true } catch { r.leftovers.append(Self.tilde(paths.copy, paths)) }
            } else {
                r.appTrashed = true
            }
        }
        // 6. brew uninstall の案内
        if !homebrewRemoved { r.brewCommand = "brew uninstall \(AppIdentifiers.formula)" }
        return r
    }

    enum StopResult: Equatable {
        case stopped
        case notUnregistered(String)
        case notConfirmed(unregistered: Bool, String)
    }

    /// Host の登録を解除し、プロセスが終わるのを待つ。`state.json` が止まっていて、かつ Host の識別子のプロセスも無い時だけ「止まった」。
    /// `state.json` を読めない（`.unknown`）時は確かめられないので中止する（点検 A）
    private func stopHost() async -> StopResult {
        // 登録が無い（notRegistered・notFound）時だけ解除を飛ばす。状態を読めない（unknown）時も解除を試み、解除の後の状態で判断する（再点検 軽微 6）
        let before = ports.loginItem.status()
        var unregistered = false
        if before != .notRegistered, before != .notFound {
            do { try ports.loginItem.unregister(); unregistered = true } catch {
                let after = ports.loginItem.status()
                guard after == .notRegistered || after == .notFound else { return .notUnregistered("unregister: \(error) (status: \(after))") }
                unregistered = before != .unknown
            }
        }
        var waited = 0.0
        var asked = false
        while true {
            let state = ports.hostState()
            if state == .unknown { return .notConfirmed(unregistered: unregistered, "host-control/state.json can’t be read") }
            let process = ports.hostProcessRunning()
            if state == .stopped, !process { return .stopped }
            if waited >= Self.hostStopTimeout {
                return .notConfirmed(unregistered: unregistered,
                                     "ShareScale Host is still running after \(Int(Self.hostStopTimeout)) s (state: \(state), process: \(process))")
            }
            if !asked, waited >= Self.quitRequestAfter { ports.askHostToQuit(); asked = true }
            await ports.sleep(Self.pollInterval)
            waited += Self.pollInterval
        }
    }

    private func exists(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0
    }

    private func trashIfPresent(_ u: URL, _ r: inout UninstallReport) {
        guard exists(u) else { return }
        do { try ports.trash(u) } catch { r.leftovers.append(Self.tilde(u, paths)) }
    }

    /// 秘密の削除（段 3）。`support`（`Application Support/ShareScale`）から `pairings`・`host`・`viewer` を
    /// `open(O_DIRECTORY|O_NOFOLLOW)`／`openat` でたどらずに開き、開いたものを `fstat` で本人の本物のフォルダと確かめる（リンク・他人のもの・フォルダでないものは**中止**。
    /// 無いものだけ飛ばす）。消すのは `<32 hex>.key`・`<32 hex>.meta`・`.<32 hex>.….tmp` の形だけで、それ以外の名前があれば何も消さずに中止して一覧を示す。
    /// `.key` を先に `unlinkat` で消し（リンクはリンクだけが消える）、`.key` か `.tmp`（書きかけの秘密）が 1 つでも残れば理由を返す（点検 B・再点検）
    static func deleteSecrets(support: URL, uid: uid_t = geteuid()) -> String? {
        func openChecked(_ at: Int32?, _ name: String) -> (fd: Int32?, problem: String?) {
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let fd = at.map { openat($0, name, flags) } ?? open(name, flags)
            if fd < 0 {
                let e = errno
                return e == ENOENT ? (nil, nil) : (nil, "\(name): not a real folder (\(String(cString: strerror(e))))")
            }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else { close(fd); return (nil, "\(name): not your folder") }
            return (fd, nil)
        }
        let top = openChecked(nil, support.path)
        if let p = top.problem { return p }
        guard let supportFD = top.fd else { return nil }
        defer { close(supportFD) }
        let pr = openChecked(supportFD, "pairings")
        if let p = pr.problem { return p }
        guard let pairingsFD = pr.fd else { return nil }
        defer { close(pairingsFD) }
        var roles: [(name: String, fd: Int32, files: [String])] = []
        defer { roles.forEach { close($0.fd) } }
        for role in ["host", "viewer"] {
            let r = openChecked(pairingsFD, role)
            if let p = r.problem { return "pairings/" + p }
            guard let fd = r.fd else { continue }
            guard let files = names(in: fd) else { close(fd); return "pairings/\(role): unreadable" }
            roles.append((role, fd, files))
            let unexpected = files.filter { !isSecretFileName($0) }
            if !unexpected.isEmpty { return "pairings/\(role): unexpected items: " + unexpected.sorted().joined(separator: ", ") }
        }
        for r in roles {
            for n in r.files.filter({ $0.hasSuffix(".key") }) + r.files.filter({ !$0.hasSuffix(".key") }) { unlinkat(r.fd, n, 0) }
            _ = ProtectedFiles.fullSync(r.fd)
            // 鍵と一時ファイル（秘密を含む）が 1 つでも残れば中止（再点検 軽微 4）
            let left = (names(in: r.fd) ?? r.files).filter { $0.hasSuffix(".key") || $0.hasSuffix(".tmp") }
            if !left.isEmpty { return "pairings/\(r.name): \(left.count) key or temporary file(s) remain" }
        }
        return nil
    }

    /// 開いたフォルダの中の名前（`.`・`..` を除く。リンクをたどらない。読めなければ nil）
    static func names(in fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let dir = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(dir) }
        rewinddir(dir)
        var out: [String] = []
        while let e = readdir(dir) {
            // dirent 全体を写さず、名前を d_namlen の長さだけ読む（再点検 軽微 4）
            let length = Int(e.pointee.d_namlen)
            let name = withUnsafePointer(to: &e.pointee.d_name) { p in
                p.withMemoryRebound(to: UInt8.self, capacity: length) { String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self) }
            }
            if name != ".", name != ".." { out.append(name) }
        }
        return out
    }

    /// 消してよい秘密のファイルの名前（`<32 hex>.key`・`<32 hex>.meta`・`.<32 hex>.<…>.tmp`）
    static func isSecretFileName(_ n: String) -> Bool {
        let hex = Set("0123456789abcdef")
        func isID(_ s: Substring) -> Bool { s.count == Limits.idHexLength && s.allSatisfy(hex.contains) }
        if n.hasSuffix(".key") { return isID(n.dropLast(4)) }
        if n.hasSuffix(".meta") { return isID(n.dropLast(5)) }
        if n.hasPrefix("."), n.hasSuffix(".tmp") {
            let body = n.dropFirst().dropLast(4)
            guard let dot = body.firstIndex(of: ".") else { return false }
            return isID(body[..<dot]) && body.count > Limits.idHexLength + 1
        }
        return false
    }
}
